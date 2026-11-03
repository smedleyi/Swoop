import Foundation

public struct Modifiers: OptionSet, Codable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let command = Modifiers(rawValue: 1 << 0)
    public static let option = Modifiers(rawValue: 1 << 1)
    public static let control = Modifiers(rawValue: 1 << 2)
    public static let shift = Modifiers(rawValue: 1 << 3)
}

public protocol SettingOption: CaseIterable, Codable, Hashable, Identifiable, RawRepresentable
where RawValue == String {
    var label: String { get }
}

extension SettingOption {
    public var id: String { rawValue }
}

public enum AppsToShow: String, SettingOption {
    case all, active, nonActive, underCursor, appUnderCursor
    public var label: String {
        switch self {
        case .all: return "All apps"
        case .active: return "Active app"
        case .nonActive: return "All apps except the active one"
        case .underCursor: return "Windows under the cursor"
        case .appUnderCursor: return "App under the cursor"
        }
    }
}

public enum SpacesToShow: String, SettingOption {
    case all, visible, nonVisible
    public var label: String {
        switch self {
        case .all: return "All Spaces"
        case .visible: return "Visible Spaces"
        case .nonVisible: return "Other Spaces"
        }
    }
}

public enum ScreensToShow: String, SettingOption {
    case all, showingSwitcher
    public var label: String {
        self == .all ? "All screens" : "Screen showing the switcher"
    }
}

public enum ShowHow: String, SettingOption {
    case show, hide, atEnd
    public var label: String {
        switch self {
        case .show: return "Show"
        case .hide: return "Hide"
        case .atEnd: return "Show at the end"
        }
    }
}

public enum WindowOrder: String, SettingOption {
    case recentlyFocused, recentlyCreated, alphabetical, space
    public var label: String {
        switch self {
        case .recentlyFocused: return "Recently focused"
        case .recentlyCreated: return "Recently created"
        case .alphabetical: return "Alphabetical"
        case .space: return "By Space"
        }
    }
}

public enum Grouping: String, SettingOption {
    case allWindows, oneWindowPerApp
    public var label: String {
        self == .allWindows ? "All windows" : "One window per app"
    }
}

public enum TabHandling: String, SettingOption {
    case singleWindow, separateWindows
    public var label: String {
        self == .singleWindow ? "Show tabs as one window" : "Show each tab separately"
    }
}

public enum ReleaseAction: String, SettingOption {
    case focus, nothing, search
    public var label: String {
        switch self {
        case .focus: return "Switch to the selected window"
        case .nothing: return "Keep the switcher open"
        case .search: return "Start searching"
        }
    }
}

public enum SwitcherStyle: String, SettingOption {
    case thumbnails, appIcons, titles
    public var label: String {
        switch self {
        case .thumbnails: return "Thumbnails"
        case .appIcons: return "App icons"
        case .titles: return "Titles"
        }
    }
}

public enum SwitcherSize: String, SettingOption {
    case small, medium, large, auto
    public var label: String { rawValue.capitalized }
}

public enum Theme: String, SettingOption {
    case system, light, dark
    public var label: String { rawValue.capitalized }
}

public enum ShowOnScreen: String, SettingOption {
    case active, mouse, menuBar
    public var label: String {
        switch self {
        case .active: return "Screen with the active window"
        case .mouse: return "Screen with the mouse"
        case .menuBar: return "Screen with the active menu bar"
        }
    }
}

public enum TitleTruncation: String, SettingOption {
    case start, middle, end
    public var label: String { rawValue.capitalized }
}

public enum TitleContent: String, SettingOption {
    case windowTitle, appName, appNameAndWindowTitle
    public var label: String {
        switch self {
        case .windowTitle: return "Window title"
        case .appName: return "App name"
        case .appNameAndWindowTitle: return "App name and window title"
        }
    }
}

public enum CursorFollow: String, SettingOption {
    case never, always, differentScreen
    public var label: String {
        switch self {
        case .never: return "Never"
        case .always: return "Always"
        case .differentScreen: return "When the window is on another screen"
        }
    }
}

public enum Gesture: String, SettingOption {
    case disabled, threeHorizontal, threeVertical, fourHorizontal, fourVertical
    public var label: String {
        switch self {
        case .disabled: return "Off"
        case .threeHorizontal: return "Three fingers, sideways"
        case .threeVertical: return "Three fingers, up or down"
        case .fourHorizontal: return "Four fingers, sideways"
        case .fourVertical: return "Four fingers, up or down"
        }
    }
    public var fingers: Int { self == .threeHorizontal || self == .threeVertical ? 3 : 4 }
    public var isHorizontal: Bool { self == .threeHorizontal || self == .fourHorizontal }
}

public enum ExceptionHide: String, SettingOption {
    case never, always, whenNoOpenWindow, whenTitleContains
    public var label: String {
        switch self {
        case .never: return "Never hide"
        case .always: return "Always hide"
        case .whenNoOpenWindow: return "Hide when it has no windows"
        case .whenTitleContains: return "Hide when the title contains"
        }
    }
}

public enum ExceptionIgnore: String, SettingOption {
    case never, always, whenFullscreen
    public var label: String {
        switch self {
        case .never: return "Use Swoop's shortcuts"
        case .always: return "Ignore Swoop's shortcuts"
        case .whenFullscreen: return "Ignore them when full screen"
        }
    }
}

/// An app with its own rules. A bundle ID ending in "." matches any ID starting with it.
public struct AppException: Codable, Hashable, Identifiable {
    public var id = UUID()
    public var bundleID: String
    public var hide: ExceptionHide
    public var titleText: String
    public var ignore: ExceptionIgnore

    public init(bundleID: String, hide: ExceptionHide = .never, titleText: String = "",
                ignore: ExceptionIgnore = .never) {
        self.bundleID = bundleID
        self.hide = hide
        self.titleText = titleText
        self.ignore = ignore
    }

    public func matches(_ other: String?) -> Bool {
        guard let other, !bundleID.isEmpty else { return false }
        return bundleID.hasSuffix(".") ? other.hasPrefix(bundleID) : other == bundleID
    }
}

/// What a set of windows looks like and how it behaves, independent of how it's opened.
public struct WindowScope: Codable, Equatable {
    public var apps = AppsToShow.all
    public var spaces = SpacesToShow.all
    public var screens = ScreensToShow.all
    public var minimized = ShowHow.show
    public var hidden = ShowHow.show
    public var fullscreen = ShowHow.show
    public var windowlessApps = ShowHow.hide
    public var order = WindowOrder.recentlyFocused
    public var grouping = Grouping.allWindows
    public var tabs = TabHandling.singleWindow
    public var onRelease = ReleaseAction.focus

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try c.fill(&apps, .apps)
        try c.fill(&spaces, .spaces)
        try c.fill(&screens, .screens)
        try c.fill(&minimized, .minimized)
        try c.fill(&hidden, .hidden)
        try c.fill(&fullscreen, .fullscreen)
        try c.fill(&windowlessApps, .windowlessApps)
        try c.fill(&order, .order)
        try c.fill(&grouping, .grouping)
        try c.fill(&tabs, .tabs)
        try c.fill(&onRelease, .onRelease)
    }
}

public struct Shortcut: Codable, Equatable, Identifiable {
    public var id = UUID()
    /// Held to keep the switcher open. Releasing them runs the scope's release action.
    public var hold: Modifiers
    public var keyCode: Int
    public var scope = WindowScope()

    public init(hold: Modifiers, keyCode: Int, scope: WindowScope = WindowScope()) {
        self.hold = hold
        self.keyCode = keyCode
        self.scope = scope
    }
}

/// Keys that act on the selected window while the switcher is open. Nil means unassigned.
public struct SessionKeys: Codable, Equatable {
    public var focus: Int? = KeyCode.return
    public var previous: Int?
    public var cancel: Int? = KeyCode.escape
    public var close: Int? = KeyCode.w
    public var minimize: Int? = KeyCode.m
    public var fullscreen: Int? = KeyCode.f
    public var quit: Int? = KeyCode.q
    public var hide: Int? = KeyCode.h
    public var search: Int? = KeyCode.s

    private enum CodingKeys: String, CodingKey {
        case focus, previous, cancel, close, minimize, fullscreen, quit, hide, search
    }

    private static let fields: [(CodingKeys, WritableKeyPath<SessionKeys, Int?>)] = [
        (.focus, \.focus), (.previous, \.previous), (.cancel, \.cancel), (.close, \.close),
        (.minimize, \.minimize), (.fullscreen, \.fullscreen), (.quit, \.quit), (.hide, \.hide),
        (.search, \.search),
    ]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Present but null means the user unassigned it, so it mustn't fall back to the default.
        for (key, path) in Self.fields where c.contains(key) {
            self[keyPath: path] = try c.decodeIfPresent(Int.self, forKey: key)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        for (key, path) in Self.fields {
            try c.encode(self[keyPath: path], forKey: key)
        }
    }
}

public enum KeyCode {
    public static let tab = 48
    public static let `return` = 36
    public static let keypadEnter = 76
    public static let escape = 53
    public static let delete = 51
    public static let left = 123
    public static let right = 124
    public static let down = 125
    public static let up = 126
    public static let w = 13
    public static let m = 46
    public static let f = 3
    public static let q = 12
    public static let h = 4
    public static let j = 38
    public static let k = 40
    public static let l = 37
    public static let s = 1
    public static let grave = 50
}

public struct Settings: Codable, Equatable {
    public static let maxShortcuts = 9

    public var shortcuts = [
        Shortcut(hold: .command, keyCode: KeyCode.tab),
        Shortcut(hold: .option, keyCode: KeyCode.tab),
    ]
    public var keys = SessionKeys()
    public var arrowKeys = true
    public var vimKeys = false
    public var mouseHover = true
    public var cursorFollow = CursorFollow.never
    public var showDelayMs = 120
    public var gesture = Gesture.disabled
    public var gestureScope = WindowScope()
    public var gestureHaptics = true

    public var style = SwitcherStyle.thumbnails
    public var size = SwitcherSize.auto
    public var theme = Theme.system
    public var showOnScreen = ShowOnScreen.mouse
    public var titleTruncation = TitleTruncation.end
    public var titleContent = TitleContent.windowTitle
    public var hideThumbnails = false
    public var showCloseButton = true
    public var showMinimizeButton = false
    public var showFullscreenButton = false
    public var hideStatusIcons = false
    public var hideSpaceNumbers = true
    public var previewSelected = false
    public var fadeOut = false

    public var menuBarIconShown = true
    public var fullScreenMenuBarButtons = false
    public var exceptions: [AppException] = Settings.defaultExceptions

    private enum LegacyKeys: String, CodingKey {
        case hideCircles
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try c.fill(&shortcuts, .shortcuts)
        try c.fill(&keys, .keys)
        try c.fill(&arrowKeys, .arrowKeys)
        try c.fill(&vimKeys, .vimKeys)
        try c.fill(&mouseHover, .mouseHover)
        try c.fill(&cursorFollow, .cursorFollow)
        try c.fill(&showDelayMs, .showDelayMs)
        try c.fill(&gesture, .gesture)
        try c.fill(&gestureScope, .gestureScope)
        try c.fill(&gestureHaptics, .gestureHaptics)
        try c.fill(&style, .style)
        try c.fill(&size, .size)
        try c.fill(&theme, .theme)
        try c.fill(&showOnScreen, .showOnScreen)
        try c.fill(&titleTruncation, .titleTruncation)
        try c.fill(&titleContent, .titleContent)
        try c.fill(&hideThumbnails, .hideThumbnails)
        // Before each button had its own setting, one setting hid them all.
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        let hidAllButtons = try legacy.decodeIfPresent(Bool.self, forKey: .hideCircles) ?? false
        showCloseButton = try c.decodeIfPresent(Bool.self, forKey: .showCloseButton) ?? !hidAllButtons
        try c.fill(&showMinimizeButton, .showMinimizeButton)
        try c.fill(&showFullscreenButton, .showFullscreenButton)
        try c.fill(&hideStatusIcons, .hideStatusIcons)
        try c.fill(&hideSpaceNumbers, .hideSpaceNumbers)
        try c.fill(&previewSelected, .previewSelected)
        try c.fill(&fadeOut, .fadeOut)
        try c.fill(&menuBarIconShown, .menuBarIconShown)
        try c.fill(&fullScreenMenuBarButtons, .fullScreenMenuBarButtons)
        try c.fill(&exceptions, .exceptions)
    }

    /// Remote desktops and VMs need ⌘Tab for themselves when they fill the screen,
    /// and Finder is always running, so it only counts when it has a window.
    public static let defaultExceptions: [AppException] = [
        AppException(bundleID: "com.apple.finder", hide: .whenNoOpenWindow),
        AppException(bundleID: "com.apple.ScreenSharing", ignore: .whenFullscreen),
        AppException(bundleID: "com.microsoft.rdc.macos", ignore: .whenFullscreen),
        AppException(bundleID: "com.teamviewer.TeamViewer", ignore: .whenFullscreen),
        AppException(bundleID: "org.virtualbox.app.VirtualBoxVM", ignore: .whenFullscreen),
        AppException(bundleID: "com.parallels.", ignore: .whenFullscreen),
        AppException(bundleID: "com.citrix.XenAppViewer", ignore: .whenFullscreen),
        AppException(bundleID: "com.citrix.receiver.icaviewer.mac", ignore: .whenFullscreen),
        AppException(bundleID: "com.vmware.fusion", ignore: .whenFullscreen),
        AppException(bundleID: "com.utmapp.UTM", ignore: .whenFullscreen),
    ]

    /// True when Swoop's shortcuts should be released for this app to use.
    public func ignoresShortcuts(frontBundleID: String?, isFullscreen: Bool) -> Bool {
        exceptions.contains { exception in
            guard exception.matches(frontBundleID) else { return false }
            switch exception.ignore {
            case .never: return false
            case .always: return true
            case .whenFullscreen: return isFullscreen
            }
        }
    }

    /// Holding shift as well goes backward, unless another shortcut uses that combination.
    public func isReverseFree(for shortcut: Shortcut) -> Bool {
        !shortcuts.contains { $0.keyCode == shortcut.keyCode && $0.hold == shortcut.hold.union(.shift) }
    }

    /// Shortcuts that would claim the same key press, by position in `shortcuts`.
    public var conflictingShortcuts: Set<Int> {
        let groups = Dictionary(grouping: shortcuts.indices) { "\(shortcuts[$0].hold.rawValue)-\(shortcuts[$0].keyCode)" }
        return Set(groups.values.filter { $0.count > 1 }.joined())
    }
}

private extension KeyedDecodingContainer {
    /// Reads a setting, leaving its default in place when it isn't saved.
    func fill<T: Decodable>(_ value: inout T, _ key: Key) throws {
        value = try decodeIfPresent(T.self, forKey: key) ?? value
    }
}
