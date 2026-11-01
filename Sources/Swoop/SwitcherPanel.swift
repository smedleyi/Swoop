import AppKit
import SwoopCore

enum TileAction {
    case close, minimize, fullscreen
}

/// The tile grid. It never takes focus, so the frontmost app stays frontmost
/// until a window is actually chosen.
final class SwitcherPanel: NSPanel {
    var onClick: ((Int) -> Void)?
    var onHover: ((Int) -> Void)?
    var onTileAction: ((Int, TileAction) -> Void)?
    private(set) var columns = 1

    private static let padding: CGFloat = 16
    private static let gap: CGFloat = 6
    private static let screenFraction: CGFloat = 0.9
    private static let pointerCheckInterval: TimeInterval = 1.0 / 30
    private static let cornerRadius: CGFloat = 28
    private static let searchHeight: CGFloat = 54
    private static let searchMinimumWidth: CGFloat = 640

    /// Everything sits in here, on top of whichever backdrop this macOS has.
    private let content = NSView()
    private let searchIcon = NSImageView()
    private let searchLabel = NSTextField(labelWithString: "")
    private let searchDivider = NSView()
    /// Scrolls only when even the smallest tiles won't all fit on screen.
    private let scroll = NSScrollView()
    private let document = NSView()
    private var tiles = [TileView]()
    /// Tracking areas never reported hovering on this panel, though clicks arrive fine,
    /// so while it's open the pointer is checked directly.
    private var pointerTimer: Timer?
    private var lastPointer = NSPoint.zero

    init() {
        super.init(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        content.autoresizingMask = [.width, .height]
        if #available(macOS 26.0, *) {
            // Liquid Glass, the material Spotlight and ⌘Tab use.
            let glass = NSGlassEffectView()
            glass.cornerRadius = Self.cornerRadius
            glass.contentView = content
            contentView = glass
        } else {
            let blur = NSVisualEffectView()
            blur.material = .hudWindow
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.cornerRadius = Self.cornerRadius
            blur.layer?.masksToBounds = true
            content.frame = blur.bounds
            blur.addSubview(content)
            contentView = blur
        }

        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .medium))
        searchIcon.contentTintColor = .secondaryLabelColor
        content.addSubview(searchIcon)

        searchLabel.font = .systemFont(ofSize: 22)
        searchLabel.lineBreakMode = .byTruncatingHead
        content.addSubview(searchLabel)

        searchDivider.wantsLayer = true
        content.addSubview(searchDivider)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = document
        content.addSubview(scroll)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// `query` is nil unless searching.
    func show(items: [WindowItem], selected: Int, on screen: NSScreen, settings: Settings, query: String?) {
        switch settings.theme {
        case .system: appearance = nil
        case .light: appearance = NSAppearance(named: .aqua)
        case .dark: appearance = NSAppearance(named: .darkAqua)
        }
        alphaValue = 1
        layOut(items: items, on: screen.visibleFrame, settings: settings, query: query)
        select(selected)
        orderFrontRegardless()
        watchPointer()
    }

    private func watchPointer() {
        guard pointerTimer == nil else { return }
        lastPointer = NSEvent.mouseLocation
        let timer = Timer(timeInterval: Self.pointerCheckInterval, repeats: true) { [weak self] _ in
            self?.pointerCheck()
        }
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
    }

    private func pointerCheck() {
        let pointer = NSEvent.mouseLocation
        // A tile appearing under a still mouse isn't the mouse choosing it.
        guard pointer != lastPointer else { return }
        lastPointer = pointer
        tiles.forEach { $0.refreshHover() }
        if let index = tiles.firstIndex(where: \.isHovered) { onHover?(index) }
    }

    func select(_ index: Int) {
        for (i, tile) in tiles.enumerated() {
            tile.isSelected = i == index
        }
        if tiles.indices.contains(index) { tiles[index].scrollToVisible(tiles[index].bounds) }
    }

    func setThumbnail(_ image: CGImage, at index: Int) {
        guard tiles.indices.contains(index) else { return }
        tiles[index].setThumbnail(image)
    }

    func dismiss(fade: Bool) {
        pointerTimer?.invalidate()
        pointerTimer = nil
        guard fade, isVisible else {
            orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.alphaValue == 0 else { return }
            self.orderOut(nil)
        })
    }

    private func layOut(items: [WindowItem], on area: NSRect, settings: Settings, query: String?) {
        tiles.forEach { $0.removeFromSuperview() }
        let maxWidth = area.width * Self.screenFraction
        let searchSpace = query == nil ? 0 : Self.searchHeight
        let maxHeight = area.height * Self.screenFraction - searchSpace

        // The largest tiles that still fit everything on screen.
        var tileSize = NSSize.zero
        var columnCount = 1
        for candidate in TileView.sizes(style: settings.style, size: settings.size) {
            let fit = settings.style == .titles
                ? 1 : max(1, Int((maxWidth - Self.padding * 2 + Self.gap) / (candidate.width + Self.gap)))
            let rows = Self.rows(items.count, columns: fit)
            let height = Self.padding * 2 + CGFloat(rows) * candidate.height + CGFloat(rows - 1) * Self.gap
            tileSize = candidate
            columnCount = fit
            if height <= maxHeight { break }
        }
        columnCount = min(columnCount, max(items.count, 1))
        columns = columnCount

        let rows = Self.rows(items.count, columns: columnCount)
        let tilesWidth = Self.padding * 2 + CGFloat(columnCount) * tileSize.width + CGFloat(columnCount - 1) * Self.gap
        // Nothing to show means no tile area, just the search text.
        let tilesHeight = items.isEmpty ? 0 : CGFloat(rows) * tileSize.height + CGFloat(rows - 1) * Self.gap
        let documentHeight = query != nil && items.isEmpty ? 0 : Self.padding * 2 + tilesHeight
        let visibleHeight = min(documentHeight, maxHeight)
        let size = NSSize(
            width: query == nil ? tilesWidth : max(tilesWidth, min(Self.searchMinimumWidth, maxWidth)),
            height: visibleHeight + searchSpace)
        // Tiles stay centered when the search bar makes the panel wider than they are.
        let tilesLeft = (size.width - tilesWidth) / 2 + Self.padding

        searchLabel.isHidden = query == nil
        searchIcon.isHidden = query == nil
        searchDivider.isHidden = query == nil || items.isEmpty
        if let query {
            let noMatches = items.isEmpty && !query.isEmpty
            searchLabel.stringValue = query.isEmpty ? "Search windows" : noMatches ? "No matches for “\(query)”" : query
            searchLabel.textColor = query.isEmpty || noMatches ? .secondaryLabelColor : .labelColor
            let centerY = size.height - Self.searchHeight / 2
            searchIcon.frame = NSRect(x: 18, y: centerY - 12, width: 24, height: 24)
            searchLabel.frame = NSRect(x: 50, y: centerY - 14, width: size.width - 68, height: 28)
            searchDivider.frame = NSRect(x: 0, y: size.height - Self.searchHeight, width: size.width, height: 1)
            searchDivider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        }

        tiles = items.enumerated().map { index, item in
            let tile = TileView(item: item, size: tileSize, settings: settings)
            tile.onClick = { [weak self] in self?.onClick?(index) }
            tile.onAction = { [weak self] action in self?.onTileAction?(index, action) }
            let row = index / columnCount
            let column = index % columnCount
            tile.frame.origin = NSPoint(
                x: tilesLeft + CGFloat(column) * (tileSize.width + Self.gap),
                y: documentHeight - Self.padding - tileSize.height
                    - CGFloat(row) * (tileSize.height + Self.gap))
            document.addSubview(tile)
            return tile
        }
        setFrame(
            NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                   width: size.width, height: size.height),
            display: false)
        scroll.frame = NSRect(x: 0, y: 0, width: size.width, height: visibleHeight)
        document.frame = NSRect(x: 0, y: 0, width: size.width, height: documentHeight)
        // Back to the top, from where `select` brings the highlighted tile into view.
        document.scroll(NSPoint(x: 0, y: documentHeight))
        display()
        invalidateShadow()
        tiles.forEach { $0.refreshHover() }
    }

    private static func rows(_ count: Int, columns: Int) -> Int {
        max(1, (count + columns - 1) / columns)
    }
}

private final class TileView: NSView {
    var onClick: (() -> Void)?
    var onAction: ((TileAction) -> Void)?

    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            // A neutral wash, like ⌘Tab. It's resolved here because a layer can't follow
            // light and dark on its own.
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.backgroundColor = isSelected
                    ? NSColor.labelColor.withAlphaComponent(0.16).cgColor
                    : NSColor.clear.cgColor
            }
            updateButtons()
            updateCaption()
        }
    }

    private(set) var isHovered = false {
        didSet {
            if isHovered != oldValue { updateButtons() }
        }
    }

    private static let inset: CGFloat = 8
    private static let captionHeight: CGFloat = 22
    private static let smallIcon: CGFloat = 18
    private static let previewRatio: CGFloat = 0.625
    private static let previewGap: CGFloat = 4
    private static let thumbnailCaptionHeight: CGFloat = 18
    private static let thumbnailBottomInset: CGFloat = 4
    private static let buttonSize: CGFloat = 20
    private static let minimumWidthForAllButtons: CGFloat = 110

    private let preview = NSImageView()
    private var caption: NSTextField?
    /// ⌘Tab only names the selected app, which keeps a row of icons calm.
    private let captionOnlyWhenSelected: Bool
    private var hoverButtons = [TileButton]()
    private var closeButton: TileButton?
    private let showsThumbnail: Bool

    /// Largest first. A fixed size only shrinks when the windows wouldn't fit otherwise.
    static func sizes(style: SwitcherStyle, size: SwitcherSize) -> [NSSize] {
        switch style {
        case .thumbnails:
            let widths: [CGFloat]
            switch size {
            case .small: widths = [160, 115, 95]
            case .medium: widths = [230, 170, 115, 95]
            case .large: widths = [320, 240, 170, 115, 95]
            case .auto: widths = [320, 240, 200, 170, 140, 115, 95]
            }
            return widths.map {
                NSSize(
                    width: $0,
                    height: inset + ($0 - inset * 2) * previewRatio + previewGap + thumbnailCaptionHeight + thumbnailBottomInset)
            }
        case .appIcons:
            let widths: [CGFloat]
            switch size {
            case .small: widths = [84, 70]
            case .medium: widths = [110, 84, 70]
            case .large, .auto: widths = [140, 110, 84, 70]
            }
            return widths.map { NSSize(width: $0, height: $0 + captionHeight) }
        case .titles:
            let rowHeights: [CGFloat]
            let width: CGFloat
            switch size {
            case .small: (width, rowHeights) = (380, [26, 22])
            case .medium: (width, rowHeights) = (500, [32, 26, 22])
            case .large, .auto: (width, rowHeights) = (620, [38, 32, 26, 22])
            }
            return rowHeights.map { NSSize(width: width, height: $0) }
        }
    }

    init(item: WindowItem, size: NSSize, settings: Settings) {
        showsThumbnail = settings.style == .thumbnails && !settings.hideThumbnails && !item.facts.isWindowless
        captionOnlyWhenSelected = settings.style == .appIcons
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.cornerRadius = settings.style == .titles ? 10 : 16

        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.image = item.icon
        addSubview(preview)

        switch settings.style {
        case .thumbnails: layOutThumbnail(item, size: size, settings: settings)
        case .appIcons: layOutIcon(item, size: size, settings: settings)
        case .titles: layOutTitle(item, size: size, settings: settings)
        }

        if item.element != nil {
            addButtons(size: size, settings: settings)
        }
        updateButtons()
        updateCaption()
    }

    private func updateCaption() {
        caption?.isHidden = captionOnlyWhenSelected && !isSelected
        caption?.textColor = isSelected ? .labelColor : .secondaryLabelColor
        caption?.font = .systemFont(ofSize: 12, weight: isSelected ? .medium : .regular)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func layOutThumbnail(_ item: WindowItem, size: NSSize, settings: Settings) {
        let previewWidth = size.width - Self.inset * 2
        let previewBottom = Self.thumbnailBottomInset + Self.thumbnailCaptionHeight + Self.previewGap
        preview.frame = NSRect(
            x: Self.inset, y: previewBottom,
            width: previewWidth, height: previewWidth * Self.previewRatio)
        // Wide windows don't fill the frame, and this keeps them next to their title.
        preview.imageAlignment = .alignBottom
        preview.wantsLayer = true
        let lift = NSShadow()
        lift.shadowColor = NSColor.black.withAlphaComponent(0.28)
        lift.shadowBlurRadius = 8
        lift.shadowOffset = NSSize(width: 0, height: -2)
        preview.shadow = lift
        if showsThumbnail, let cached = Thumbnails.shared.cached(item.id) { setThumbnail(cached) }

        // The icon and title are centered together. Measured at the selected weight, the
        // widest the title gets, and long titles still shorten to fit the tile.
        let measuring = NSTextField(labelWithString: Self.caption(for: item, content: settings.titleContent))
        measuring.font = .systemFont(ofSize: 12, weight: .medium)
        // With a little to spare, because a title that's a fraction too wide loses several
        // letters. It's centered in this space, so the spare width doesn't show.
        let titleWidth = min(ceil(measuring.fittingSize.width) + 4, previewWidth - Self.smallIcon - 5)
        let left = (size.width - (Self.smallIcon + 5 + titleWidth)) / 2

        let icon = NSImageView(frame: NSRect(
            x: left, y: Self.thumbnailBottomInset + (Self.thumbnailCaptionHeight - Self.smallIcon) / 2,
            width: Self.smallIcon, height: Self.smallIcon))
        icon.image = item.icon
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)

        addCaption(item, settings: settings, frame: NSRect(
            x: left + Self.smallIcon + 5,
            y: Self.thumbnailBottomInset + (Self.thumbnailCaptionHeight - 17) / 2,
            width: titleWidth, height: 17), alignment: .center)
        addStatus(item, settings: settings, trailing: size.width - Self.inset - 4, y: previewBottom + 4)
    }

    private func layOutIcon(_ item: WindowItem, size: NSSize, settings: Settings) {
        let side = size.width - Self.inset * 2
        preview.frame = NSRect(x: Self.inset, y: Self.captionHeight + 2, width: side, height: side)
        addCaption(item, settings: settings, frame: NSRect(
            x: 4, y: 4, width: size.width - 8, height: 17), alignment: .center)
        addStatus(item, settings: settings, trailing: size.width - Self.inset, y: Self.captionHeight + 4)
    }

    private func layOutTitle(_ item: WindowItem, size: NSSize, settings: Settings) {
        let side = min(size.height - 6, 28)
        preview.frame = NSRect(x: Self.inset, y: (size.height - side) / 2, width: side, height: side)
        // Clear of the buttons, which sit at the end of the row.
        let buttonCount = item.element == nil ? 0 : Self.enabledButtons(settings).count
        let buttonSpace = CGFloat(buttonCount) * (Self.buttonSize + 4)
        addCaption(item, settings: settings, frame: NSRect(
            x: Self.inset + side + 8, y: (size.height - 17) / 2,
            width: size.width - Self.inset * 2 - side - 8 - 70 - buttonSpace, height: 17), alignment: .left)
        addStatus(item, settings: settings, trailing: size.width - Self.inset - buttonSpace, y: (size.height - 14) / 2)
    }

    private func addCaption(_ item: WindowItem, settings: Settings, frame: NSRect, alignment: NSTextAlignment) {
        let label = NSTextField(labelWithString: Self.caption(for: item, content: settings.titleContent))
        caption = label
        label.alignment = alignment
        switch settings.titleTruncation {
        case .start: label.lineBreakMode = .byTruncatingHead
        case .middle: label.lineBreakMode = .byTruncatingMiddle
        case .end: label.lineBreakMode = .byTruncatingTail
        }
        label.frame = frame
        addSubview(label)
    }

    /// Minimized, hidden and full-screen badges, and the Space number.
    private func addStatus(_ item: WindowItem, settings: Settings, trailing: CGFloat, y: CGFloat) {
        var x = trailing
        func place(_ view: NSView, width: CGFloat) {
            x -= width
            view.frame = NSRect(x: x, y: y, width: width, height: 14)
            addSubview(view)
            x -= 4
        }
        if !settings.hideStatusIcons {
            let symbols = [
                (item.facts.isMinimized, "minus.circle.fill", "Minimized"),
                (item.facts.isAppHidden, "eye.slash.fill", "Hidden"),
                (item.facts.isFullscreen, "arrow.up.left.and.arrow.down.right.circle.fill", "Full screen"),
            ]
            for (isOn, symbol, description) in symbols where isOn {
                let view = NSImageView()
                view.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
                view.contentTintColor = .labelColor
                place(view, width: 14)
            }
        }
        if !settings.hideSpaceNumbers, let number = item.spaceNumber {
            let label = NSTextField(labelWithString: "\(number)")
            label.font = .boldSystemFont(ofSize: 11)
            label.alignment = .right
            place(label, width: 20)
        }
    }

    private typealias ButtonSpec = (symbol: String, label: String, action: TileAction, hover: NSColor)

    /// The buttons turned on in Settings, outermost first.
    private static func enabledButtons(_ settings: Settings) -> [ButtonSpec] {
        var specs = [ButtonSpec]()
        if settings.showCloseButton { specs.append(("xmark", "Close window", .close, .systemRed)) }
        if settings.showMinimizeButton { specs.append(("minus", "Minimize window", .minimize, .darkGray)) }
        if settings.showFullscreenButton {
            specs.append(("arrow.up.left.and.arrow.down.right", "Toggle full screen", .fullscreen, .darkGray))
        }
        return specs
    }

    /// A row in the top corner, with the X outermost. Tiles too narrow for several
    /// buttons keep only the first.
    private func addButtons(size: NSSize, settings: Settings) {
        let side = min(Self.buttonSize, size.height - 4)
        let y = settings.style == .titles ? (size.height - side) / 2 : size.height - side - 4
        var specs = Self.enabledButtons(settings)
        if size.width < Self.minimumWidthForAllButtons { specs = Array(specs.prefix(1)) }
        for (index, spec) in specs.enumerated() {
            let button = TileButton(symbol: spec.symbol, label: spec.label, hoverColor: spec.hover) { [weak self] in
                self?.onAction?(spec.action)
            }
            button.frame = NSRect(
                x: size.width - 4 - side - CGFloat(index) * (side + 4), y: y, width: side, height: side)
            button.layer?.cornerRadius = side / 2
            addSubview(button)
            if spec.action == .close {
                closeButton = button
            } else {
                hoverButtons.append(button)
            }
        }
    }

    private func updateButtons() {
        hoverButtons.forEach { $0.isHidden = !isHovered }
        closeButton?.isHidden = !(isHovered || isSelected)
    }

    /// Also called after layout, so when closing a window slides the next tile under a
    /// still cursor, its X shows anyway.
    func refreshHover() {
        guard let window else { return }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        // Only the part showing, as a tile can be scrolled out of view.
        isHovered = visibleRect.contains(point)
        for button in hoverButtons + [closeButton].compactMap({ $0 }) {
            button.isPointerOver = button.frame.contains(point)
        }
    }

    func setThumbnail(_ image: CGImage) {
        guard showsThumbnail else { return }
        preview.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private static func caption(for item: WindowItem, content: TitleContent) -> String {
        let facts = item.facts
        if facts.isWindowless || facts.title.isEmpty { return facts.appName }
        switch content {
        case .windowTitle: return facts.title
        case .appName: return facts.appName
        case .appNameAndWindowTitle: return "\(facts.appName): \(facts.title)"
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

/// A small round button in a tile's corner. It lights up under the mouse, and clicking
/// it leaves the switcher open, so several windows can be closed in a row.
private final class TileButton: NSButton {
    private let onPress: () -> Void
    private let hoverColor: NSColor
    private static let restingColor = NSColor.black.withAlphaComponent(0.6).cgColor

    init(symbol: String, label: String, hoverColor: NSColor, onPress: @escaping () -> Void) {
        self.onPress = onPress
        self.hoverColor = hoverColor
        super.init(frame: .zero)
        isBordered = false
        title = ""
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .bold))
        imagePosition = .imageOnly
        contentTintColor = .white
        toolTip = label
        setAccessibilityLabel(label)
        wantsLayer = true
        layer?.backgroundColor = Self.restingColor
        target = self
        action = #selector(pressed)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func pressed() {
        onPress()
    }

    var isPointerOver = false {
        didSet {
            guard isPointerOver != oldValue else { return }
            layer?.backgroundColor = isPointerOver ? hoverColor.cgColor : Self.restingColor
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Shows the selected window at full size where it really is, on top of everything
/// except the switcher.
final class WindowPreview: NSPanel {
    private let imageView = NSImageView()

    init() {
        super.init(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        imageView.imageScaling = .scaleAxesIndependently
        contentView = imageView
    }

    override var canBecomeKey: Bool { false }

    /// Full-size captures are large, so one isn't kept while hidden.
    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        imageView.image = nil
    }

    func show(_ image: CGImage, windowServerFrame frame: CGRect) {
        guard frame.width > 0 else { return }
        imageView.image = NSImage(cgImage: image, size: frame.size)
        setFrame(WindowList.flipped(frame), display: true)
        orderFrontRegardless()
    }
}
