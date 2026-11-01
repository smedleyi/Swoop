import Foundation

/// Everything the filters need to know about one tile.
public struct WindowFacts: Equatable {
    public var id: UInt32
    public var pid: Int32
    public var bundleID: String?
    public var title: String
    public var appName: String
    public var isMinimized = false
    public var isAppHidden = false
    public var isFullscreen = false
    public var spaceIDs: [UInt64] = []
    public var isOnVisibleSpace = true
    public var screenIndex: Int?
    /// A running app with nothing open. Selecting it activates the app.
    public var isWindowless = false
    /// A background tab of a native macOS tab group.
    public var isInactiveTab = false

    public init(id: UInt32, pid: Int32, bundleID: String? = nil, title: String = "", appName: String = "") {
        self.id = id
        self.pid = pid
        self.bundleID = bundleID
        self.title = title
        self.appName = appName
    }
}

/// The state of the Mac at the moment the switcher opens.
public struct ArrangementContext {
    public var activePid: Int32?
    public var recency: [UInt32] = []
    public var switcherScreenIndex: Int?
    public var windowUnderCursor: UInt32?
    public var pidUnderCursor: Int32?
    /// Space IDs left to right.
    public var spaceOrder: [UInt64] = []

    public init() {}
}

public enum Arrangement {
    /// Filters and sorts windows for a scope. Anything set to "show at the end" sorts
    /// behind the rest, in the same order among themselves.
    public static func arrange(
        _ windows: [WindowFacts], scope: WindowScope, exceptions: [AppException], context: ArrangementContext
    ) -> [WindowFacts] {
        let visible = windows.filter { isVisible($0, scope: scope, exceptions: exceptions, context: context) }
        let sorted = sort(visible, order: scope.order, context: context)
        let front = sorted.filter { !goesAtEnd($0, scope: scope) }
        let back = sorted.filter { goesAtEnd($0, scope: scope) }
        let result = front + back
        guard scope.grouping == .oneWindowPerApp else { return result }
        var seen = Set<Int32>()
        return result.filter { seen.insert($0.pid).inserted }
    }

    private static func isVisible(
        _ window: WindowFacts, scope: WindowScope, exceptions: [AppException], context: ArrangementContext
    ) -> Bool {
        for exception in exceptions where exception.matches(window.bundleID) {
            switch exception.hide {
            case .never: break
            case .always: return false
            case .whenNoOpenWindow: if window.isWindowless { return false }
            case .whenTitleContains:
                if !exception.titleText.isEmpty,
                   window.title.localizedCaseInsensitiveContains(exception.titleText) { return false }
            }
        }

        if window.isWindowless && scope.windowlessApps == .hide { return false }
        if window.isMinimized && scope.minimized == .hide { return false }
        if window.isAppHidden && scope.hidden == .hide { return false }
        if window.isFullscreen && scope.fullscreen == .hide { return false }
        if window.isInactiveTab && scope.tabs == .singleWindow { return false }

        switch scope.apps {
        case .all: break
        case .active: if window.pid != context.activePid { return false }
        case .nonActive: if window.pid == context.activePid { return false }
        case .underCursor: if window.id != context.windowUnderCursor { return false }
        case .appUnderCursor: if window.pid != context.pidUnderCursor { return false }
        }

        // Windowless apps aren't on any Space or screen, so those filters can't apply.
        if window.isWindowless { return true }

        switch scope.spaces {
        case .all: break
        case .visible: if !window.isOnVisibleSpace { return false }
        case .nonVisible: if window.isOnVisibleSpace { return false }
        }
        if scope.screens == .showingSwitcher, window.screenIndex != context.switcherScreenIndex {
            return false
        }
        return true
    }

    private static func goesAtEnd(_ window: WindowFacts, scope: WindowScope) -> Bool {
        (window.isWindowless && scope.windowlessApps == .atEnd)
            || (window.isMinimized && scope.minimized == .atEnd)
            || (window.isAppHidden && scope.hidden == .atEnd)
            || (window.isFullscreen && scope.fullscreen == .atEnd)
    }

    private static func sort(
        _ windows: [WindowFacts], order: WindowOrder, context: ArrangementContext
    ) -> [WindowFacts] {
        var rank = [UInt32: Int]()
        for (index, id) in context.recency.enumerated() where rank[id] == nil { rank[id] = index }
        let recency: (WindowFacts) -> Int = { rank[$0.id] ?? Int.max }

        func byName(_ a: WindowFacts, _ b: WindowFacts) -> Bool {
            let result = a.appName.localizedCaseInsensitiveCompare(b.appName)
            if result != .orderedSame { return result == .orderedAscending }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }

        switch order {
        case .recentlyFocused:
            return windows.sorted { a, b in
                recency(a) != recency(b) ? recency(a) < recency(b) : byName(a, b)
            }
        case .recentlyCreated:
            // Window IDs only go up, so a higher ID is a newer window.
            return windows.sorted { $0.id > $1.id }
        case .alphabetical:
            return windows.sorted(by: byName)
        case .space:
            var spaceRank = [UInt64: Int]()
            for (index, id) in context.spaceOrder.enumerated() { spaceRank[id] = index }
            let space: (WindowFacts) -> Int = { window in
                window.spaceIDs.compactMap { spaceRank[$0] }.min() ?? Int.max
            }
            return windows.sorted { a, b in
                if space(a) != space(b) { return space(a) < space(b) }
                return recency(a) != recency(b) ? recency(a) < recency(b) : byName(a, b)
            }
        }
    }

    /// Search results: contiguous matches first, then the letters in order.
    public static func search(_ windows: [WindowFacts], query: String) -> [WindowFacts] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return windows }
        let exact = windows.filter { haystack($0).contains(needle) }
        let loose = windows.filter { !haystack($0).contains(needle) && isSubsequence(needle, of: haystack($0)) }
        return exact + loose
    }

    private static func haystack(_ window: WindowFacts) -> String {
        "\(window.appName) \(window.title)".lowercased()
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var remaining = Substring(needle)
        for character in haystack where remaining.first == character {
            remaining.removeFirst()
            if remaining.isEmpty { return true }
        }
        return remaining.isEmpty
    }
}
