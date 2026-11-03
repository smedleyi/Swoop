import AppKit
import SwoopCore

struct WindowItem {
    var facts: WindowFacts
    let icon: NSImage?
    /// Nil for a windowless app.
    let element: AXUIElement?
    /// In window-server coordinates, with the origin at the top left of the main screen.
    let frame: CGRect
    /// The position of each Space, for the number on the tile.
    var spaceNumber: Int?

    var id: CGWindowID { facts.id }
}

/// Keeps a list of switchable windows up to date in the background, so the
/// switcher can open instantly instead of asking every app when you press Tab.
final class WindowList {
    static let shared = WindowList()

    /// Called on the main thread after each refresh.
    var onChange: (() -> Void)?
    /// While the switcher is open, what it does doesn't count as using a window.
    var isFrozen = false
    private var focusChangesIgnoredUntil = Date.distantPast
    private var isTrackingFocus: Bool { !isFrozen && Date() >= focusChangesIgnoredUntil }

    private(set) var byID = [CGWindowID: WindowItem]()
    private(set) var spaceOrder = [UInt64]()
    private var recency = RecencyList()
    private let queue = DispatchQueue(label: "com.isaac.swoop.windowlist", qos: .userInitiated)
    private var isRefreshing = false
    private var needsAnotherRefresh = false

    // Only touched on `queue`. Every element seen, because an app only lists the windows
    // on the current Space and these still work once a window has left it. Then the
    // windows that have been searched for and not found, so one that never turns up isn't
    // searched for every time, but a search that only failed because the app was busy, or
    // the window was new, gets another go.
    private var knownElements = [CGWindowID: AXUIElement]()
    private var knownIDs = [pid_t: Set<CGWindowID>]()
    private var missedScans = [CGWindowID: (attempts: Int, next: Date)]()
    // Also only touched on `queue`. What each app last reported, and who's being observed.
    private var lastItems = [CGWindowID: WindowItem]()
    private var observers = [pid_t: AXObserver]()
    private var observedWindows = [pid_t: Set<CGWindowID>]()

    private var pendingRefresh: DispatchWorkItem?

    private static let elementTimeout: Float = 0.25
    private static let scanBudget: TimeInterval = 0.25
    private static let firstScanRetry: TimeInterval = 5
    private static let longestScanRetry: TimeInterval = 300
    /// Keeps windowless apps' tile IDs clear of real window IDs.
    private static let windowlessIDBase: CGWindowID = 0x8000_0000
    /// Windows that open or close together only cause one refresh.
    private static let eventRefreshDelay: TimeInterval = 0.15

    var recencyOrder: [UInt32] { recency.order }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
        ] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            }
        }
        center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let key = NSWorkspace.applicationUserInfoKey
            guard let app = notification.userInfo?[key] as? NSRunningApplication else { return }
            self?.noteActivation(of: app.processIdentifier)
        }
        // A safety net for apps that don't report changes. Everything else is event driven.
        let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // Lets macOS bundle these wake-ups with others, which saves battery.
        timer.tolerance = 5
        refresh()
    }

    func refresh() {
        guard !isRefreshing else {
            needsAnotherRefresh = true
            return
        }
        isRefreshing = true
        let apps = Self.switchableApps()
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let screens = Self.screenFrames()
        queue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.takeSnapshot(apps: apps, frontPid: frontPid, screens: screens)
            DispatchQueue.main.async { self.apply(snapshot) }
        }
    }

    /// Called for changes an app reports, on the main thread.
    fileprivate func handleEvent(_ element: AXUIElement, _ notification: String) {
        if notification == kAXFocusedWindowChangedNotification {
            if isTrackingFocus, let id = PrivateAPI.windowID(of: element) { recency.touch(id) }
            return
        }
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.eventRefreshDelay, execute: work)
    }

    /// Switching apps quickly can outrun refreshes, so each one is noted as it happens.
    private func noteActivation(of pid: pid_t) {
        queue.async { [weak self] in
            guard let id = Self.focusedWindowID(pid: pid, timeout: Self.elementTimeout) else { return }
            DispatchQueue.main.async {
                guard let self, self.isTrackingFocus else { return }
                self.recency.touch(id)
            }
        }
    }

    /// Moves the frontmost app's focused window to the top of the list, in case the
    /// app is one that doesn't report focus changes.
    func noteFocusedWindow() -> CGWindowID? {
        guard let id = focusedWindowID(), byID[id] != nil else { return nil }
        recency.touch(id)
        return id
    }

    /// For while a slide between Spaces moves focus through windows nobody chose.
    func ignoreFocusChanges(until date: Date) {
        focusChangesIgnoredUntil = date
    }

    func noteSwitched(to id: CGWindowID) {
        recency.touch(id)
    }

    private func focusedWindowID() -> CGWindowID? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        return Self.focusedWindowID(pid: pid, timeout: 0.05)
    }

    /// Converts between AppKit's coordinates, which start at the bottom left of the
    /// main screen, and the window server's, which start at its top left.
    static func flipped(_ rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func screenFrames() -> [CGRect] {
        NSScreen.screens.map { flipped($0.frame) }
    }

    /// The frontmost normal window under the pointer.
    static func windowUnderCursor() -> (id: CGWindowID, pid: pid_t)? {
        let point = CGEvent(source: nil)?.location ?? .zero
        let window = windowServerWindows([.optionOnScreenOnly, .excludeDesktopElements]).first {
            $0.layer == 0 && $0.bounds.contains(point)
        }
        return window.map { ($0.id, $0.pid) }
    }

    private static func switchableApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != getpid()
        }
    }

    private func apply(_ snapshot: Snapshot) {
        byID = snapshot.items
        spaceOrder = snapshot.spaceOrder
        recency.reconcile(with: snapshot.frontToBack)
        if isTrackingFocus, let focused = snapshot.focused, byID[focused] != nil {
            recency.touch(focused)
        }
        isRefreshing = false
        onChange?()
        if needsAnotherRefresh {
            needsAnotherRefresh = false
            refresh()
        }
    }

    /// For `Swoop --check`. Prints app names and counts, not window titles.
    func printCheck() {
        let start = Date()
        let snapshot = takeSnapshot(
            apps: Self.switchableApps(),
            frontPid: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            screens: Self.screenFrames())
        let items = snapshot.items.values.filter { !$0.facts.isWindowless }
        print("Windows: \(items.count) in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        print("Windowless apps: \(snapshot.items.count - items.count)")
        print("Spaces: \(snapshot.spaceOrder.count)")
        print("Minimized: \(items.filter(\.facts.isMinimized).count)")
        print("Full screen: \(items.filter(\.facts.isFullscreen).count)")
        print("Background tabs: \(items.filter(\.facts.isInactiveTab).count)")
        print("Focused window found: \(snapshot.focused.map { snapshot.items[$0] != nil } ?? false)")
        let counts = Dictionary(grouping: items, by: \.facts.appName).mapValues(\.count)
        for (name, count) in counts.sorted(by: { $0.key < $1.key }) {
            print("  \(name): \(count)")
        }
        let captured = items.filter { PrivateAPI.captureWindow($0.id) != nil }.count
        print("Previews captured: \(captured) of \(items.count)")
    }

    // MARK: - Reading windows (background)

    private struct Snapshot {
        var items = [CGWindowID: WindowItem]()
        var frontToBack = [CGWindowID]()
        var focused: CGWindowID?
        var spaceOrder = [UInt64]()
    }

    private func takeSnapshot(apps: [NSRunningApplication], frontPid: pid_t?, screens: [CGRect]) -> Snapshot {
        let candidates = Self.windowServerCandidates()
        let layout = PrivateAPI.spaceLayout()

        var snapshot = Snapshot()
        snapshot.spaceOrder = layout.ordered
        for app in apps {
            let pid = app.processIdentifier
            let ids = Set(candidates.byPid[pid] ?? [])
            observe(pid: pid)
            guard let found = elements(pid: pid, candidates: ids) else {
                // Too busy to answer isn't the same as having no windows, so what it
                // last reported stands until the window server says those windows are gone.
                let windowless = Self.windowlessID(pid)
                for (id, item) in lastItems where ids.contains(id) || id == windowless {
                    snapshot.items[id] = item
                }
                continue
            }
            var hasWindow = false
            for (id, element) in found {
                observe(window: element, id: id, pid: pid)
                let last = lastItems[id]
                if let item = Self.makeItem(
                    id: id, element: element, app: app, frame: candidates.frames[id] ?? .zero,
                    layout: layout, screens: screens, lastSpaces: last?.facts.spaceIDs) {
                    snapshot.items[id] = item
                    hasWindow = true
                } else if let last, axIsBusy(element) {
                    snapshot.items[id] = last
                    hasWindow = true
                }
            }
            observedWindows[pid] = observedWindows[pid]?.intersection(ids)
            if !hasWindow {
                let item = Self.makeWindowlessItem(app)
                snapshot.items[item.id] = item
            }
        }
        stopObservingApps(except: Set(apps.map(\.processIdentifier)))
        lastItems = snapshot.items
        snapshot.frontToBack = candidates.frontToBack.filter { snapshot.items[$0] != nil }
            + snapshot.items.keys.filter { $0 >= Self.windowlessIDBase }.sorted()
        if let frontPid {
            snapshot.focused = Self.focusedWindowID(pid: frontPid, timeout: Self.elementTimeout)
        }
        return snapshot
    }

    /// The window server knows every window on every Space, but not what each one
    /// is, so it decides which windows exist and Accessibility decides what they are.
    private static func windowServerCandidates() -> (
        byPid: [pid_t: [CGWindowID]], frontToBack: [CGWindowID], frames: [CGWindowID: CGRect]
    ) {
        var byPid = [pid_t: [CGWindowID]]()
        var frontToBack = [CGWindowID]()
        var frames = [CGWindowID: CGRect]()
        for window in windowServerWindows([.optionAll, .excludeDesktopElements]) where WindowFilter.isSubstantial(
            layer: window.layer, width: Double(window.bounds.width), height: Double(window.bounds.height)
        ) {
            byPid[window.pid, default: []].append(window.id)
            frontToBack.append(window.id)
            frames[window.id] = window.bounds
        }
        return (byPid, frontToBack, frames)
    }

    private static func windowServerWindows(
        _ options: CGWindowListOption
    ) -> [(id: CGWindowID, pid: pid_t, layer: Int, bounds: CGRect)] {
        let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        return info.compactMap { window in
            guard let id = window[kCGWindowNumber as String] as? CGWindowID,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  let boundsInfo = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo)
            else { return nil }
            return (id, pid, layer, bounds)
        }
    }

    // MARK: - Observing apps (background)

    private func observe(pid: pid_t) {
        guard observers[pid] == nil else { return }
        var created: AXObserver?
        guard AXObserverCreate(pid, axEventCallback, &created) == .success, let observer = created else { return }
        let app = axApp(pid, timeout: Self.elementTimeout)
        for notification in [kAXFocusedWindowChangedNotification, kAXWindowCreatedNotification] {
            // Asked again next time, once the app is answering.
            if AXObserverAddNotification(observer, app, notification as CFString, nil) == .cannotComplete { return }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
    }

    private func observe(window: AXUIElement, id: CGWindowID, pid: pid_t) {
        guard let observer = observers[pid], observedWindows[pid]?.contains(id) != true else { return }
        for notification in [kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
            if AXObserverAddNotification(observer, window, notification as CFString, nil) == .cannotComplete { return }
        }
        observedWindows[pid, default: []].insert(id)
    }

    private func stopObservingApps(except running: Set<pid_t>) {
        for (pid, observer) in observers where !running.contains(pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            observers[pid] = nil
            observedWindows[pid] = nil
        }
    }

    // MARK: - Reading elements (background)

    /// Nil if the app is too busy to answer.
    private func elements(pid: pid_t, candidates: Set<CGWindowID>) -> [CGWindowID: AXUIElement]? {
        let app = axApp(pid, timeout: Self.elementTimeout)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard result != .cannotComplete else { return nil }

        var found = [CGWindowID: AXUIElement]()
        for window in value as? [AXUIElement] ?? [] {
            if let id = PrivateAPI.windowID(of: window), candidates.contains(id) {
                found[id] = window
                knownElements[id] = window
            }
        }
        for id in candidates where found[id] == nil {
            if let known = knownElements[id] { found[id] = known }
        }

        // Forget windows that have closed.
        for id in (knownIDs[pid] ?? []).subtracting(candidates) {
            knownElements[id] = nil
            missedScans[id] = nil
        }
        knownIDs[pid] = candidates

        let now = Date()
        let due = candidates.subtracting(found.keys).filter { (missedScans[$0]?.next ?? now) <= now }
        if !due.isEmpty {
            var remaining = due
            PrivateAPI.scanElements(pid: pid, budget: Self.scanBudget) { element in
                AXUIElementSetMessagingTimeout(element, Self.elementTimeout)
                guard let id = PrivateAPI.windowID(of: element), remaining.contains(id),
                      axValue(element, kAXRoleAttribute) == kAXWindowRole as String
                else { return false }
                found[id] = element
                knownElements[id] = element
                missedScans[id] = nil
                remaining.remove(id)
                return remaining.isEmpty
            }
            for id in remaining {
                let attempts = (missedScans[id]?.attempts ?? 0) + 1
                let wait = min(Self.firstScanRetry * pow(2, Double(attempts - 1)), Self.longestScanRetry)
                missedScans[id] = (attempts, now.addingTimeInterval(wait))
            }
        }
        return found
    }

    private static func makeItem(
        id: CGWindowID, element: AXUIElement, app: NSRunningApplication, frame: CGRect,
        layout: (ordered: [UInt64], visible: Set<UInt64>), screens: [CGRect], lastSpaces: [UInt64]?
    ) -> WindowItem? {
        AXUIElementSetMessagingTimeout(element, elementTimeout)
        guard WindowFilter.isSwitchable(
            role: axValue(element, kAXRoleAttribute), subrole: axValue(element, kAXSubroleAttribute))
        else { return nil }

        var facts = WindowFacts(
            id: id, pid: app.processIdentifier, bundleID: app.bundleIdentifier,
            title: axValue(element, kAXTitleAttribute) ?? "", appName: app.localizedName ?? "")
        facts.isMinimized = axValue(element, kAXMinimizedAttribute) ?? false
        facts.isAppHidden = app.isHidden
        facts.isFullscreen = axValue(element, axFullScreenAttribute) ?? false
        // When the Spaces can't be read at all, nothing is assumed about the window.
        if let spaces = PrivateAPI.spaces(of: id) {
            facts.isInactiveTab = spaces.isEmpty && !facts.isMinimized && !facts.isAppHidden
            // Minimized and hidden windows can report no Space, so the last known one
            // stands. With none known, a window isn't filtered out for being elsewhere.
            let known = spaces.isEmpty ? lastSpaces ?? [] : spaces
            facts.spaceIDs = known
            facts.isOnVisibleSpace = known.isEmpty || known.contains { layout.visible.contains($0) }
        }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        facts.screenIndex = screens.firstIndex { $0.contains(center) }

        let spaceNumber = facts.spaceIDs.first.flatMap { layout.ordered.firstIndex(of: $0) }.map { $0 + 1 }
        return WindowItem(facts: facts, icon: app.icon, element: element, frame: frame, spaceNumber: spaceNumber)
    }

    private static func windowlessID(_ pid: pid_t) -> CGWindowID {
        windowlessIDBase | CGWindowID(truncatingIfNeeded: pid)
    }

    private static func makeWindowlessItem(_ app: NSRunningApplication) -> WindowItem {
        var facts = WindowFacts(
            id: windowlessID(app.processIdentifier),
            pid: app.processIdentifier, bundleID: app.bundleIdentifier,
            title: "", appName: app.localizedName ?? "")
        facts.isWindowless = true
        facts.isAppHidden = app.isHidden
        return WindowItem(facts: facts, icon: app.icon, element: nil, frame: .zero, spaceNumber: nil)
    }

    private static func focusedWindowID(pid: pid_t, timeout: Float) -> CGWindowID? {
        axElement(axApp(pid, timeout: timeout), kAXFocusedWindowAttribute).flatMap(PrivateAPI.windowID)
    }
}

// MARK: - Accessibility

private let axEventCallback: AXObserverCallback = { _, element, notification, _ in
    WindowList.shared.handleEvent(element, notification as String)
}

/// A timed-out request, which says nothing about whether the window still exists.
private func axIsBusy(_ element: AXUIElement) -> Bool {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .cannotComplete
}

private let axFullScreenAttribute = "AXFullScreen"

private func axApp(_ pid: pid_t, timeout: Float) -> AXUIElement {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, timeout)
    return app
}

private func axValue<T>(_ element: AXUIElement, _ attribute: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value as? T
}

/// Elements need their own check, because `as?` can't cast to a Core Foundation type.
private func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
          let value, CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    return (value as! AXUIElement)
}

private func pressCloseButton(of element: AXUIElement) {
    guard let button = axElement(element, kAXCloseButtonAttribute) else {
        NSSound.beep()
        return
    }
    AXUIElementPerformAction(button, kAXPressAction as CFString)
}

/// An app's focused window while it's in full screen, looked up fresh each time.
struct FullscreenWindow {
    private static let timeout: Float = 0.25
    private static let exitPollInterval: TimeInterval = 0.2
    private static let exitPollAttempts = 25
    /// The window says it has left full screen before the animation ends, and macOS
    /// brings back a window minimized before then.
    private static let exitAnimationDelay: TimeInterval = 1
    private static let minimizeRetryDelay: TimeInterval = 0.5
    private static let minimizeAttempts = 3

    private let element: AXUIElement

    static func focused(pid: pid_t) -> FullscreenWindow? {
        guard let element = axElement(axApp(pid, timeout: timeout), kAXFocusedWindowAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(element, timeout)
        guard axValue(element, axFullScreenAttribute) == true else { return nil }
        return FullscreenWindow(element: element)
    }

    static func isBusy(pid: pid_t) -> Bool {
        axIsBusy(axApp(pid, timeout: timeout))
    }

    func close() {
        pressCloseButton(of: element)
    }

    func exitFullscreen() {
        AXUIElementSetAttributeValue(element, axFullScreenAttribute as CFString, kCFBooleanFalse)
    }

    func minimize(on queue: DispatchQueue) {
        exitFullscreen()
        minimizeAfterExit(on: queue, attemptsLeft: Self.exitPollAttempts)
    }

    private func minimizeAfterExit(on queue: DispatchQueue, attemptsLeft: Int) {
        guard axValue(element, axFullScreenAttribute) == false else {
            guard attemptsLeft > 1 else { return }
            queue.asyncAfter(deadline: .now() + Self.exitPollInterval) {
                minimizeAfterExit(on: queue, attemptsLeft: attemptsLeft - 1)
            }
            return
        }
        queue.asyncAfter(deadline: .now() + Self.exitAnimationDelay) {
            keepMinimized(on: queue, attemptsLeft: Self.minimizeAttempts)
        }
    }

    private func keepMinimized(on queue: DispatchQueue, attemptsLeft: Int) {
        if axValue(element, kAXMinimizedAttribute) != true {
            AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        }
        guard attemptsLeft > 1 else { return }
        queue.asyncAfter(deadline: .now() + Self.minimizeRetryDelay) {
            keepMinimized(on: queue, attemptsLeft: attemptsLeft - 1)
        }
    }
}

// MARK: - Acting on a window

extension WindowItem {
    private var app: NSRunningApplication? {
        NSRunningApplication(processIdentifier: facts.pid)
    }

    func perform(_ action: TileAction) {
        switch action {
        case .close: close()
        case .minimize: toggleMinimized()
        case .fullscreen: toggleFullscreen()
        }
    }

    /// Brings this window forward, restoring it first if it's hidden or minimized.
    func focus() {
        if facts.isAppHidden { app?.unhide() }
        guard let element else {
            // Activating an app with no windows is what makes most of them open one.
            app?.activate()
            if let url = app?.bundleURL {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
            return
        }
        if facts.isMinimized {
            AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        PrivateAPI.focus(pid: facts.pid, windowID: id)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    /// For when `focus` didn't take, with the public way of asking as well.
    func refocus() {
        focus()
        app?.activate()
    }

    func close() {
        guard let element else { return }
        pressCloseButton(of: element)
    }

    func toggleMinimized() {
        guard let element else { return }
        let value: CFBoolean = facts.isMinimized ? kCFBooleanFalse : kCFBooleanTrue
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, value)
    }

    func toggleFullscreen() {
        guard let element else { return }
        let value: CFBoolean = facts.isFullscreen ? kCFBooleanFalse : kCFBooleanTrue
        AXUIElementSetAttributeValue(element, axFullScreenAttribute as CFString, value)
    }

    func quitApp() {
        // Finder relaunches itself straight away, unless it's been set up to quit.
        guard facts.bundleID != "com.apple.finder" else {
            NSSound.beep()
            return
        }
        app?.terminate()
    }

    func toggleAppHidden() {
        if facts.isAppHidden {
            app?.unhide()
        } else {
            app?.hide()
        }
    }
}
