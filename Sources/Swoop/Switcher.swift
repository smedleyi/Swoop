import AppKit
import Carbon.HIToolbox
import SwoopCore

/// Runs one press-and-hold of a shortcut: open on the first press, cycle while the
/// modifier is held, and act when it's released.
///
/// The first press arrives as a Carbon hotkey. The event tap that sees everything
/// else only runs while the switcher is open, so ordinary typing never passes
/// through Swoop. AltTab found an always-on tap like this breaks some input methods.
final class Switcher {
    static let shared = Switcher()

    private static let hotkeySignature: OSType = 0x5377_7021 // "Swp!"
    private static let releasePollInterval: TimeInterval = 0.05

    private let panel = SwitcherPanel()
    private let previewWindow = WindowPreview()
    /// Everything that could show, before any search.
    private var allItems = [WindowItem]()
    private var items = [WindowItem]()
    /// Every window this session has shown, so one that drops out of a refresh and
    /// comes back returns to its old place instead of moving to the end.
    private var sessionOrder = [CGWindowID]()
    private static let focusCheckDelay: TimeInterval = 0.5
    private static let focusRetries = 3
    private let focusQueue = DispatchQueue(label: "com.isaac.swoop.focus", qos: .userInteractive)
    private var pendingFocus: DispatchWorkItem?
    private var focusConfirmation: DispatchWorkItem?
    /// Measured on macOS 27: a slide takes about 0.4s, then macOS picks the front app.
    private static let spaceSlideDuration: TimeInterval = 0.5
    private static let slideSettleMargin: TimeInterval = 0.1
    private static let jumpArrivalLimit: TimeInterval = 0.3
    private static let jumpLandingLimit: TimeInterval = 1
    private var jumpLanding: (space: UInt64, at: Date)?
    private var slideEnds: Date?
    private var heldFocus: DispatchWorkItem?
    private var destination: WindowItem?
    /// The state of the Mac when the switcher opened.
    private var sessionContext = ArrangementContext()
    private var capturedIDs = Set<CGWindowID>()
    private var selection = Selection(count: 0)
    private var scope = WindowScope()
    private var screen: NSScreen?
    private var isOpen = false
    private var isGestureSession = false
    private var hold: CGEventFlags = []
    private var nextKeyCode = KeyCode.tab
    /// Nil unless searching. Search keeps the switcher open after the keys are released.
    private var query: String?
    private var releaseHandled = false

    private var tap: CFMachPort?
    private var releasePoll: Timer?
    private var showWork: DispatchWorkItem?
    private var outsideClickMonitor: Any?
    private var hotkeyRefs = [EventHotKeyRef]()
    private var hotkeyHandler: EventHandlerRef?
    private var hotkeysPaused = false
    private var hotkeysIgnoredForApp = false
    /// Native ⌘Tab only goes away once Swoop has permission to replace it.
    private var isStarted = false

    private static let arrowDirections: [Int: SwipeTracker.Direction] = [
        KeyCode.left: .left, KeyCode.right: .right, KeyCode.up: .up, KeyCode.down: .down,
    ]
    private static let vimDirections: [Int: SwipeTracker.Direction] = [
        KeyCode.h: .left, KeyCode.l: .right, KeyCode.k: .up, KeyCode.j: .down,
    ]

    private var settings: Settings { SettingsStore.shared.settings }

    private var selectedItem: WindowItem? {
        items.indices.contains(selection.index) ? items[selection.index] : nil
    }

    /// The screen the pointer is on.
    private static var mouseScreenIndex: Int? {
        NSScreen.screens.firstIndex { $0.frame.contains(NSEvent.mouseLocation) }
    }

    private init() {
        panel.onClick = { [weak self] index in
            guard let self else { return }
            self.selection.update(count: self.items.count, index: index)
            self.commit()
        }
        panel.onHover = { [weak self] index in
            guard let self, self.settings.mouseHover, index != self.selection.index else { return }
            self.selection.update(count: self.items.count, index: index)
            self.selectionChanged()
        }
        panel.onTileAction = { [weak self] index, action in
            guard let self, self.items.indices.contains(index) else { return }
            // Acts on the clicked tile, leaving the highlight where it is.
            let item = self.items[index]
            self.act(on: item) { $0.perform(action) }
        }
        WindowList.shared.onChange = { [weak self] in
            self?.windowsChanged()
            self?.updateHotkeysForFrontApp()
        }
    }

    // MARK: - Setup

    func start() {
        isStarted = true
        launchWatchdog()
        // Made now, because creating a tap while the first shortcut is being held can
        // make macOS report the modifier as released, closing the switcher straight away.
        createTap()
        enableTap(false)
        WindowList.shared.start()
        applySettings()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.updateHotkeysForFrontApp()
        }
        GestureMonitor.shared.onAction = { [weak self] action in self?.gesture(action) }
        GestureMonitor.shared.isSwitcherOpen = { [weak self] in self?.isOpen ?? false }
    }

    func stop() {
        cancel()
        PrivateAPI.setNativeSwitching(commandTab: true, commandShiftTab: true)
    }

    /// Turning off native ⌘Tab outlives this process, so a separate one turns it back
    /// on however Swoop ends, including crashes and force quits.
    private func launchWatchdog() {
        guard let url = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("SwoopWatchdog")
        else { return }
        let process = Process()
        process.executableURL = url
        process.arguments = [String(getpid())]
        do {
            try process.run()
        } catch {
            NSLog("Swoop: couldn't start the watchdog: \(error)")
        }
    }

    func applySettings() {
        guard isStarted else { return }
        registerHotkeys()
        GestureMonitor.shared.update(settings.gesture)
    }

    /// While a key is being recorded in Settings, nothing should fire.
    func setHotkeysPaused(_ paused: Bool) {
        hotkeysPaused = paused
        guard isStarted else { return }
        registerHotkeys()
    }

    /// The Dock only gives up ⌘Tab if it's switched off, so that only happens when
    /// a shortcut actually wants it.
    private func registerHotkeys() {
        if hotkeyHandler == nil {
            var pressed = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                Switcher.shared.hotkeyPressed(Int(id.id))
                return noErr
            }, 1, &pressed, nil, &hotkeyHandler)
        }

        hotkeyRefs.forEach { UnregisterEventHotKey($0) }
        hotkeyRefs = []

        let tabHolds = settings.shortcuts.filter { $0.keyCode == KeyCode.tab }.map(\.hold)
        PrivateAPI.setNativeSwitching(
            commandTab: !tabHolds.contains(.command),
            commandShiftTab: !tabHolds.contains(.command) && !tabHolds.contains([.command, .shift]))

        guard !hotkeysPaused, !hotkeysIgnoredForApp else { return }
        for (index, shortcut) in settings.shortcuts.enumerated() {
            register(shortcut, id: index * 2, extra: 0)
            // Holding shift as well goes backward, unless shift is already part of the shortcut.
            if !shortcut.hold.contains(.shift) && settings.isReverseFree(for: shortcut) {
                register(shortcut, id: index * 2 + 1, extra: shiftKey)
            }
        }
    }

    private func register(_ shortcut: Shortcut, id: Int, extra: Int) {
        var ref: EventHotKeyRef?
        let hotkeyID = EventHotKeyID(signature: Self.hotkeySignature, id: UInt32(id))
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode), UInt32(Self.carbonModifiers(shortcut.hold) | extra), hotkeyID,
            GetEventDispatcherTarget(), 0, &ref)
        if status == noErr, let ref {
            hotkeyRefs.append(ref)
        } else {
            NSLog("Swoop: couldn't register a shortcut, status \(status)")
        }
    }

    private static func carbonModifiers(_ modifiers: Modifiers) -> Int {
        var result = 0
        if modifiers.contains(.command) { result |= cmdKey }
        if modifiers.contains(.option) { result |= optionKey }
        if modifiers.contains(.control) { result |= controlKey }
        if modifiers.contains(.shift) { result |= shiftKey }
        return result
    }

    private static func eventFlags(_ modifiers: Modifiers) -> CGEventFlags {
        var result: CGEventFlags = []
        if modifiers.contains(.command) { result.insert(.maskCommand) }
        if modifiers.contains(.option) { result.insert(.maskAlternate) }
        if modifiers.contains(.control) { result.insert(.maskControl) }
        if modifiers.contains(.shift) { result.insert(.maskShift) }
        return result
    }

    /// Remote desktops and VMs can claim the shortcuts for themselves.
    private func updateHotkeysForFrontApp() {
        let front = NSWorkspace.shared.frontmostApplication
        let focused = WindowList.shared.byID.values.first {
            $0.facts.pid == front?.processIdentifier && $0.facts.isFullscreen && $0.facts.isOnVisibleSpace
        }
        let ignore = settings.ignoresShortcuts(frontBundleID: front?.bundleIdentifier, isFullscreen: focused != nil)
        guard ignore != hotkeysIgnoredForApp else { return }
        hotkeysIgnoredForApp = ignore
        registerHotkeys()
    }

    private func hotkeyPressed(_ id: Int) {
        let index = id / 2
        let reversed = id % 2 == 1
        guard settings.shortcuts.indices.contains(index) else { return }
        // While open, the tap handles the key. If it couldn't be created, this is
        // the only way to keep cycling.
        if isOpen {
            if tap == nil { step(reversed: reversed) }
            return
        }
        let shortcut = settings.shortcuts[index]
        open(
            scope: shortcut.scope, hold: Self.eventFlags(shortcut.hold), nextKey: shortcut.keyCode,
            reversed: reversed, gesture: false)
    }

    // MARK: - Session

    private func open(scope: WindowScope, hold: CGEventFlags, nextKey: Int, reversed: Bool, gesture: Bool) {
        focusConfirmation?.cancel()
        let focused = isHeadingSomewhere ? destination?.id : WindowList.shared.noteFocusedWindow()
        WindowList.shared.isFrozen = true

        self.scope = scope
        self.hold = hold
        nextKeyCode = nextKey
        isGestureSession = gesture
        query = nil
        releaseHandled = false
        isOpen = true
        screen = chooseScreen(focused: focused)
        sessionContext = makeContext()
        allItems = arrangedItems()
        items = allItems
        sessionOrder = allItems.map(\.id)
        capturedIDs = []
        Thumbnails.shared.keepOnly(Set(WindowList.shared.byID.keys))
        // If the app is too busy to say which window is focused, its window is still first.
        let current = items.firstIndex { $0.id == focused }
            ?? (items.first?.facts.pid == sessionContext.activePid ? 0 : nil)
        selection = Selection(count: items.count, reversed: reversed, current: current)

        enableTap(true)
        if !hold.isEmpty {
            let poll = Timer(timeInterval: Self.releasePollInterval, repeats: true) { [weak self] _ in
                self?.checkModifierReleased()
            }
            RunLoop.main.add(poll, forMode: .common)
            releasePoll = poll
        } else {
            modifierReleased()
        }

        let work = DispatchWorkItem { [weak self] in self?.showPanel() }
        showWork = work
        let delay = TimeInterval(settings.showDelayMs) / 1000
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)

        // The key may already be up by now.
        checkModifierReleased()
        if isOpen { WindowList.shared.refresh() }
    }

    private func chooseScreen(focused: CGWindowID?) -> NSScreen? {
        switch settings.showOnScreen {
        case .mouse:
            return Self.mouseScreenIndex.map { NSScreen.screens[$0] } ?? NSScreen.main
        case .menuBar:
            return NSScreen.main
        case .active:
            if let id = focused,
               let index = WindowList.shared.byID[id]?.facts.screenIndex,
               NSScreen.screens.indices.contains(index) {
                return NSScreen.screens[index]
            }
            return NSScreen.main
        }
    }

    private func makeContext() -> ArrangementContext {
        var context = ArrangementContext()
        context.activePid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        context.spaceOrder = WindowList.shared.spaceOrder
        context.switcherScreenIndex = screen.flatMap { NSScreen.screens.firstIndex(of: $0) }
        if scope.apps == .underCursor || scope.apps == .appUnderCursor {
            let under = WindowList.windowUnderCursor()
            context.windowUnderCursor = under?.id
            context.pidUnderCursor = under?.pid
        }
        return context
    }

    private func arrangedItems() -> [WindowItem] {
        let list = WindowList.shared
        sessionContext.recency = list.recencyOrder
        let arranged = Arrangement.arrange(
            list.byID.values.map(\.facts), scope: scope, exceptions: settings.exceptions, context: sessionContext)
        return arranged.compactMap { list.byID[$0.id] }
    }

    private func showPanel() {
        showWork?.cancel()
        guard isOpen, let screen else { return }
        panel.show(items: items, selected: selection.index, on: screen, settings: settings, query: query)
        captureThumbnails()
        updatePreview()
    }

    private func captureThumbnails() {
        guard settings.style == .thumbnails, !settings.hideThumbnails else { return }
        // Each window once per session, so typing a search doesn't recapture them all.
        let ids = items.filter { !$0.facts.isWindowless && !capturedIDs.contains($0.id) }.map(\.id)
        capturedIDs.formUnion(ids)
        Thumbnails.shared.capture(ids) { [weak self] id, image in
            guard let self, self.isOpen, let index = self.items.firstIndex(where: { $0.id == id }) else { return }
            self.panel.setThumbnail(image, at: index)
        }
    }

    private func step(reversed: Bool) {
        if reversed { selection.previous() } else { selection.next() }
        selectionChanged()
    }

    private func moveRows(_ rows: Int) {
        selection.moveRows(rows, columns: panel.columns)
        selectionChanged()
    }

    private func move(_ direction: SwipeTracker.Direction) {
        switch direction {
        case .left: step(reversed: true)
        case .right: step(reversed: false)
        case .up: moveRows(-1)
        case .down: moveRows(1)
        }
    }

    private func selectionChanged() {
        panel.select(selection.index)
        updatePreview()
    }

    private func updatePreview() {
        guard settings.previewSelected, panel.isVisible, let item = selectedItem else {
            previewWindow.orderOut(nil)
            return
        }
        guard item.element != nil, !item.facts.isMinimized else {
            previewWindow.orderOut(nil)
            return
        }
        Thumbnails.shared.captureFull(item.id) { [weak self] image in
            guard let self, self.isOpen, self.selectedItem?.id == item.id else { return }
            self.previewWindow.show(image, windowServerFrame: item.frame)
        }
    }

    private func commit() {
        let chosen = selectedItem
        close()
        guard let chosen else { return }
        WindowList.shared.noteSwitched(to: chosen.id)
        moveCursor(to: chosen)
        requestFocus(chosen)
    }

    /// When a slide to another Space ends, macOS brings forward whichever app is on that
    /// Space, undoing any switch made during the slide. So a switch made during one waits
    /// for the end, and only the latest of them goes ahead.
    private func requestFocus(_ item: WindowItem) {
        focusConfirmation?.cancel()
        heldFocus?.cancel()
        heldFocus = nil
        destination = item
        guard let ends = slideEnds, ends > Date() else { return startFocus(item) }
        let held = DispatchWorkItem { [weak self] in self?.startFocus(item) }
        heldFocus = held
        DispatchQueue.main.asyncAfter(deadline: .now() + ends.timeIntervalSinceNow, execute: held)
    }

    private func startFocus(_ item: WindowItem) {
        heldFocus = nil
        slideEnds = nil
        var jump: (space: UInt64, steps: Int, right: Bool)?
        if item.element != nil, let space = Self.otherSpace(of: item.id) {
            jump = instantJump(to: space)
            let duration = jump.map { InstantSpaces.durationPerSpace * Double($0.steps) } ?? Self.spaceSlideDuration
            let ends = Date().addingTimeInterval(duration)
            slideEnds = ends
            WindowList.shared.ignoreFocusChanges(until: ends.addingTimeInterval(Self.slideSettleMargin))
        }
        let origin = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // An app too busy to answer shouldn't leave a line of old switches behind it.
        pendingFocus?.cancel()
        let work = DispatchWorkItem {
            if let jump, InstantSpaces.jump(steps: jump.steps, right: jump.right) {
                Self.waitToArrive(at: jump.space)
            }
            item.focus()
        }
        pendingFocus = work
        focusQueue.async(execute: work)
        // Going to another app can't be told apart from staying, inside the same one.
        if item.facts.pid != origin {
            confirmFocus(of: item, from: origin, attemptsLeft: Self.focusRetries)
        }
    }

    /// The route is worked out from the Space showing, so a jump can't start while another
    /// is still landing: being off by one could mean swiping past the last Space.
    private func instantJump(to space: UInt64) -> (space: UInt64, steps: Int, right: Bool)? {
        guard settings.instantSpaceSwitching, InstantSpaces.isSupported else { return nil }
        if let landing = jumpLanding, landing.at > Date(),
           !PrivateAPI.spaceLayout().visible.contains(landing.space) {
            return nil
        }
        guard let route = InstantSpaces.route(to: space) else { return nil }
        jumpLanding = (space, Date().addingTimeInterval(Self.jumpLandingLimit))
        return (space, route.steps, route.right)
    }

    /// Focusing a window on another Space starts the normal animation, so this comes first.
    private static func waitToArrive(at space: UInt64) {
        let deadline = Date().addingTimeInterval(jumpArrivalLimit)
        while Date() < deadline, !PrivateAPI.spaceLayout().visible.contains(space) {
            usleep(5_000)
        }
    }

    /// The Space to go to, if the window isn't on one showing already.
    private static func otherSpace(of id: CGWindowID) -> UInt64? {
        guard let spaces = PrivateAPI.spaces(of: id), let first = spaces.first else { return nil }
        let visible = PrivateAPI.spaceLayout().visible
        return spaces.contains { visible.contains($0) } ? nil : first
    }

    /// Mid-slide, the app in front is the one being left or passed through, not where
    /// the last switch is heading.
    private var isHeadingSomewhere: Bool {
        heldFocus != nil || (slideEnds.map { $0 > Date() } ?? false)
    }

    /// macOS sometimes drops a switch, more or less silently, so it's asked again until the
    /// app comes forward. Anything else having come forward means you've moved on, as does
    /// opening the switcher again: the original app can be in front because you went back.
    private func confirmFocus(of item: WindowItem, from origin: pid_t?, attemptsLeft: Int) {
        let check = DispatchWorkItem { [weak self] in
            guard let self, !self.isOpen, attemptsLeft > 0,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == origin
            else { return }
            self.focusQueue.async { item.refocus() }
            self.confirmFocus(of: item, from: origin, attemptsLeft: attemptsLeft - 1)
        }
        focusConfirmation = check
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.focusCheckDelay, execute: check)
    }

    private func moveCursor(to item: WindowItem) {
        guard item.element != nil, item.frame.width > 0 else { return }
        let center = CGPoint(x: item.frame.midX, y: item.frame.midY)
        switch settings.cursorFollow {
        case .never:
            return
        case .differentScreen:
            if Self.mouseScreenIndex == item.facts.screenIndex { return }
        case .always:
            break
        }
        CGWarpMouseCursorPosition(center)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    private func cancel() {
        guard isOpen else { return }
        close()
    }

    private func close() {
        isOpen = false
        showWork?.cancel()
        showWork = nil
        releasePoll?.invalidate()
        releasePoll = nil
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        // If the tap couldn't be made at launch, try again while no shortcut is being held.
        if tap == nil { createTap() }
        enableTap(false)
        panel.dismiss(fade: settings.fadeOut)
        previewWindow.orderOut(nil)
        items = []
        allItems = []
        WindowList.shared.isFrozen = false
    }

    private func checkModifierReleased() {
        guard isOpen, !releaseHandled, !hold.isEmpty else { return }
        if !CGEventSource.flagsState(.combinedSessionState).contains(hold) {
            modifierReleased()
        }
    }

    private func modifierReleased() {
        guard isOpen, !releaseHandled else { return }
        releaseHandled = true
        releasePoll?.invalidate()
        releasePoll = nil
        if query != nil {
            stayOpenAfterRelease()
            return
        }
        switch scope.onRelease {
        case .focus:
            // A shortcut with nothing to hold can't be released, so it stays open.
            if !hold.isEmpty { commit() } else if !isGestureSession { stayOpenAfterRelease() }
        case .nothing:
            stayOpenAfterRelease()
        case .search:
            startSearch()
            stayOpenAfterRelease()
        }
    }

    /// With nothing being held, the panel has to appear now and clicks elsewhere dismiss it.
    private func stayOpenAfterRelease() {
        guard isOpen else { return }
        if !panel.isVisible { showPanel() }
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.cancel()
        }
    }

    // MARK: - Acting on the selection

    private func act(_ action: @escaping (WindowItem) -> Void) {
        guard let item = selectedItem else { return }
        act(on: item, action)
    }

    private func act(on item: WindowItem, _ action: @escaping (WindowItem) -> Void) {
        DispatchQueue.global(qos: .userInteractive).async {
            action(item)
            // Most apps report the change themselves. This is for the ones that don't.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                WindowList.shared.refresh()
            }
        }
    }

    private func startSearch() {
        guard query == nil else { return }
        query = ""
        applySearch(queryChanged: true)
    }

    private func applySearch(queryChanged: Bool) {
        guard let query else { return }
        let selectedID = selectedItem?.id
        let matches = Arrangement.search(allItems.map(\.facts), query: query)
        let byID = Dictionary(allItems.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        items = matches.compactMap { byID[$0.id] }
        // New results start from the top, but a refresh leaves the highlight where it is.
        let jumpToTop = queryChanged && !query.isEmpty
        selection.update(count: items.count, index: jumpToTop ? 0 : items.firstIndex { $0.id == selectedID })
        reshowPanel()
    }

    private func reshowPanel() {
        guard panel.isVisible || query != nil else { return }
        showPanel()
    }

    /// A refresh finished while open: update the tiles, leaving them where they are.
    private func windowsChanged() {
        guard isOpen else { return }
        let selectedID = selectedItem?.id
        let before = allItems.map(\.facts)
        let latest = arrangedItems()
        let latestByID = Dictionary(latest.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let known = Set(sessionOrder)
        sessionOrder += latest.map(\.id).filter { !known.contains($0) }
        allItems = sessionOrder.compactMap { latestByID[$0] }
        guard allItems.map(\.facts) != before else { return }

        if query != nil {
            applySearch(queryChanged: false)
            return
        }
        items = allItems
        selection.update(count: items.count, index: items.firstIndex { $0.id == selectedID })
        reshowPanel()
    }

    // MARK: - Gestures

    private func gesture(_ action: SwipeTracker.Action) {
        switch action {
        case .none:
            return
        case .open(let reversed):
            guard !isOpen else { return }
            open(scope: settings.gestureScope, hold: [], nextKey: -1, reversed: reversed, gesture: true)
            haptic()
        case .step(let direction):
            guard isOpen else { return }
            move(direction)
            haptic()
        case .release:
            guard isOpen, isGestureSession, scope.onRelease == .focus else { return }
            commit()
        }
    }

    private func haptic() {
        guard settings.gestureHaptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
    }

    // MARK: - Event tap

    private func enableTap(_ enabled: Bool) {
        if let tap { CGEvent.tapEnable(tap: tap, enable: enabled) }
    }

    private func createTap() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                Switcher.shared.handleTap(type: type, event: event)
            },
            userInfo: nil)
        else { return }
        CFRunLoopAddSource(
            CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        tap = port
    }

    private func handleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS turns a tap off if it thinks it's stuck.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if isOpen, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard isOpen else { return Unmanaged.passUnretained(event) }

        if type == .flagsChanged {
            if !hold.isEmpty, !event.flags.contains(hold) {
                DispatchQueue.main.async { self.modifierReleased() }
            }
            return Unmanaged.passUnretained(event)
        }

        // Handled after returning, because all keyboard input waits on this callback.
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let shifted = event.flags.contains(.maskShift)
        DispatchQueue.main.async {
            if self.isOpen { self.handleKey(code, shifted: shifted) }
        }
        // Everything is swallowed while open, so a stray ⌘Q can't quit the app behind it.
        return nil
    }

    private func handleKey(_ code: Int, shifted: Bool) {
        let keys = settings.keys

        if code == nextKeyCode {
            // Shift only means "backward" when it isn't part of what's being held.
            step(reversed: shifted && !hold.contains(.maskShift))
            return
        }
        if code == keys.cancel { return cancel() }
        if code == keys.focus || code == KeyCode.keypadEnter { return commit() }
        if settings.arrowKeys, let direction = Self.arrowDirections[code] { return move(direction) }

        // While searching, every other key is part of the search.
        if query != nil {
            typeIntoSearch(code, shifted: shifted)
            return
        }

        if code == keys.previous { return step(reversed: true) }
        if settings.vimKeys, let direction = Self.vimDirections[code] { return move(direction) }
        if code == keys.close { act { $0.perform(.close) } }
        else if code == keys.minimize { act { $0.perform(.minimize) } }
        else if code == keys.fullscreen { act { $0.perform(.fullscreen) } }
        else if code == keys.quit { act { $0.quitApp() } }
        else if code == keys.hide { act { $0.toggleAppHidden() } }
        else if code == keys.search { startSearch() }
    }

    private func typeIntoSearch(_ code: Int, shifted: Bool) {
        guard var text = query else { return }
        if code == KeyCode.delete {
            if text.isEmpty { return }
            text.removeLast()
        } else {
            // Translated from the key itself, because the shortcut's modifiers may still
            // be held, and ⌥H would otherwise type "˙".
            guard let typed = KeyNames.character(code, shifted: shifted),
                  !typed.isEmpty,
                  typed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
            else { return }
            text += typed
        }
        query = text
        applySearch(queryChanged: true)
    }
}
