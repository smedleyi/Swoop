import AppKit

/// Close, minimize and exit buttons in the menu bar, while the front window is in full screen.
final class FullScreenButtons {
    static let shared = FullScreenButtons()

    /// Entering full screen reports the new Space before the window says it's in full screen.
    private static let settleDelays: [TimeInterval] = [0.4, 1.2]
    /// A safety net for changes nothing reports, such as one window of an app leaving full screen.
    private static let pollInterval: TimeInterval = 2

    private let queue = DispatchQueue(label: "com.isaac.swoop.fullscreenbuttons", qos: .userInitiated)
    private var isStarted = false
    private var statusItem: NSStatusItem?
    private var pollTimer: Timer?

    func start() {
        isStarted = true
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
                for delay in Self.settleDelays {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.refresh() }
                }
            }
        }
        applySettings()
    }

    func applySettings() {
        guard isStarted else { return }
        guard SettingsStore.shared.settings.fullScreenMenuBarButtons else {
            pollTimer?.invalidate()
            pollTimer = nil
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }
        if statusItem == nil { statusItem = makeStatusItem() }
        if pollTimer == nil {
            let timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
                self?.refresh()
            }
            timer.tolerance = 1
            pollTimer = timer
        }
        refresh()
    }

    private func refresh() {
        guard statusItem != nil, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        queue.async { [weak self] in
            let isFullScreen = FullscreenWindow.focused(pid: pid) != nil
            // A busy app says nothing about its window, so the buttons stay as they are.
            guard isFullScreen || !FullscreenWindow.isBusy(pid: pid) else { return }
            DispatchQueue.main.async { self?.statusItem?.isVisible = isFullScreen }
        }
    }

    private func makeStatusItem() -> NSStatusItem {
        let group = TrafficLights { [weak self] kind in self?.press(kind) }
        let item = NSStatusBar.system.statusItem(withLength: group.frame.width)
        item.autosaveName = "SwoopFullScreenButtons"
        if let button = item.button {
            // Only the lights respond, not the menu bar slot around them.
            (button.cell as? NSButtonCell)?.highlightsBy = []
            button.addSubview(group)
            group.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                group.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                group.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                group.widthAnchor.constraint(equalToConstant: group.frame.width),
                group.heightAnchor.constraint(equalToConstant: group.frame.height),
            ])
        }
        item.isVisible = false
        return item
    }

    private func press(_ kind: TrafficLights.Kind) {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        queue.async { [weak self] in
            guard let self, let window = FullscreenWindow.focused(pid: pid) else { return }
            switch kind {
            case .close: window.close()
            case .minimize: window.minimize(on: self.queue)
            case .fullscreen: window.exitFullscreen()
            }
        }
    }
}

/// The three buttons. Apple's own only draw in colour in an active window, which the menu
/// bar never is, so each one shows pictures of Apple's, taken from a window made to look active.
private final class TrafficLights: NSView {
    enum Kind: CaseIterable {
        case close, minimize, fullscreen

        var buttonType: NSWindow.ButtonType {
            switch self {
            case .close: return .closeButton
            case .minimize: return .miniaturizeButton
            case .fullscreen: return .zoomButton
            }
        }
    }

    private struct Pictures {
        let resting, hovering, pressed: NSImage?
    }

    // The sizes of the real ones, which are 14 points wide and 23 apart.
    private static let diameter: CGFloat = 14
    private static let spacing: CGFloat = 9
    private static let sidePadding: CGFloat = 6
    private static let height: CGFloat = 22

    private let onPress: (Kind) -> Void
    private var lights = [(kind: Kind, view: NSImageView)]()
    private var pictures = [Kind: Pictures]()
    private var isHovering = false
    private var pressedKind: Kind?

    init(onPress: @escaping (Kind) -> Void) {
        self.onPress = onPress
        let count = CGFloat(Kind.allCases.count)
        let width = count * Self.diameter + (count - 1) * Self.spacing + 2 * Self.sidePadding
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))
        for (index, kind) in Kind.allCases.enumerated() {
            let light = NSImageView(frame: NSRect(
                x: Self.sidePadding + CGFloat(index) * (Self.diameter + Self.spacing),
                y: (Self.height - Self.diameter) / 2,
                width: Self.diameter, height: Self.diameter))
            light.imageScaling = .scaleNone
            addSubview(light)
            lights.append((kind, light))
        }
        renderPictures()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateImages()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateImages()
    }

    // Everything comes here rather than to each light, because of how clicks arrive below.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        pressedKind = kindUnderPointer()
        updateImages()
    }

    override func mouseUp(with event: NSEvent) {
        let pressed = pressedKind
        pressedKind = nil
        updateImages()
        if let pressed, pressed == kindUnderPointer() { onPress(pressed) }
    }

    /// macOS reports every click on a menu bar item as being at the middle of the item, so
    /// the event can't say which light it was. Each light owns the full height of the menu
    /// bar, so that pushing the pointer against the top of the screen still reaches it.
    private func kindUnderPointer() -> Kind? {
        guard let window else { return nil }
        let x = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil).x
        return lights.first { abs($0.view.frame.midX - x) <= (Self.diameter + Self.spacing) / 2 }?.kind
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        renderPictures()
    }

    private func renderPictures() {
        for kind in Kind.allCases {
            pictures[kind] = Pictures(
                resting: Self.picture(of: kind, hovering: false, pressed: false, appearance: effectiveAppearance),
                hovering: Self.picture(of: kind, hovering: true, pressed: false, appearance: effectiveAppearance),
                pressed: Self.picture(of: kind, hovering: true, pressed: true, appearance: effectiveAppearance))
        }
        updateImages()
    }

    // The real ones all show their symbols together, when the pointer is over any of them.
    private func updateImages() {
        for (kind, view) in lights {
            let picture = pictures[kind]
            view.image = kind == pressedKind ? picture?.pressed : isHovering ? picture?.hovering : picture?.resting
        }
    }

    private static func picture(of kind: Kind, hovering: Bool, pressed: Bool, appearance: NSAppearance) -> NSImage? {
        let window = ActiveLookingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.collectionBehavior = [.fullScreenPrimary]
        let group = HoverGroup(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        group.isHovering = hovering
        window.contentView?.addSubview(group)
        guard let button = NSWindow.standardWindowButton(kind.buttonType, for: window.styleMask) else { return nil }
        button.frame = NSRect(x: 0, y: 0, width: diameter, height: diameter)
        group.addSubview(button)
        button.isHighlighted = pressed
        guard let rep = button.bitmapImageRepForCachingDisplay(in: button.bounds) else { return nil }
        button.cacheDisplay(in: button.bounds, to: rep)
        let image = NSImage(size: button.bounds.size)
        image.addRepresentation(rep)
        return image
    }
}

/// Never shown. It's only here so the real buttons draw as they do in a full screen window.
private final class ActiveLookingWindow: NSWindow {
    @objc var hasKeyAppearance: Bool { true }

    override var styleMask: NSWindow.StyleMask {
        get { super.styleMask.union(.fullScreen) }
        set { super.styleMask = newValue }
    }
}

/// What the real buttons ask their superview to find out whether to show their symbols.
private final class HoverGroup: NSView {
    var isHovering = false

    @objc func _mouseInGroup(_ button: NSButton) -> Bool { isHovering }
}
