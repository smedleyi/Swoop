import Foundation
import SwoopCore

var failures = 0

func check(_ condition: Bool, _ name: String) {
    print("\(condition ? "ok  " : "FAIL") \(name)")
    if !condition { failures += 1 }
}

// Selection
do {
    check(Selection(count: 3, current: 0).index == 1, "starts one past the focused window")
    check(Selection(count: 3, reversed: true, current: 0).index == 2, "shift starts one before it")
    check(Selection(count: 3, current: 2).index == 0, "a focused window at the end wraps to the start")
    check(Selection(count: 3).index == 0, "with the focused window not listed, starts on the first tile")
    check(Selection(count: 3, reversed: true).index == 2, "or with shift, on the last")
    check(Selection(count: 1, current: 0).index == 0, "a lone focused window stays on itself")
    check(Selection(count: 1).index == 0, "one window stays on itself")
    check(Selection(count: 0).index == 0, "no windows doesn't underflow")

    var s = Selection(count: 3, current: 0)
    s.next(); check(s.index == 2, "next moves forward")
    s.next(); check(s.index == 0, "next wraps to the start")
    s.previous(); check(s.index == 2, "previous wraps to the end")

    var empty = Selection(count: 0)
    empty.next(); empty.previous()
    check(empty.index == 0, "cycling an empty list is safe")

    var grid = Selection(count: 7, current: 0)
    grid.moveRows(1, columns: 3); check(grid.index == 4, "down moves one row")
    grid.moveRows(1, columns: 3); check(grid.index == 4, "down past the end stays put")
    grid.moveRows(-1, columns: 3); check(grid.index == 1, "up moves one row")
    grid.moveRows(-1, columns: 3); check(grid.index == 1, "up past the start stays put")

    var shrinking = Selection(count: 5, current: 0)
    shrinking.next(); shrinking.next(); shrinking.next()
    shrinking.update(count: 2, index: nil)
    check(shrinking.index == 1, "a shrinking list clamps the highlight")
    shrinking.update(count: 0, index: nil)
    check(shrinking.index == 0, "an emptied list resets the highlight")
    shrinking.update(count: 4, index: 3)
    check(shrinking.index == 3, "a known tile keeps the highlight")
}

// RecencyList
do {
    var r = RecencyList()
    r.reconcile(with: [10, 20, 30])
    check(r.order == [10, 20, 30], "new windows keep front-to-back order")
    r.touch(30)
    check(r.order == [30, 10, 20], "touch moves a window to the front")
    r.touch(40)
    check(r.order == [40, 30, 10, 20], "touch adds an unknown window")
    r.reconcile(with: [20, 50, 30, 50])
    check(r.order == [30, 20, 50], "reconcile drops closed windows and dedupes new ones")
    r.reconcile(with: [])
    check(r.order.isEmpty, "reconcile can empty the list")
}

// WindowFilter
do {
    check(WindowFilter.isSubstantial(layer: 0, width: 800, height: 600), "normal window passes")
    check(!WindowFilter.isSubstantial(layer: 25, width: 800, height: 600), "overlay layer is rejected")
    check(!WindowFilter.isSubstantial(layer: 0, width: 40, height: 600), "narrow sliver is rejected")
    check(!WindowFilter.isSubstantial(layer: 0, width: 800, height: 20), "short sliver is rejected")
    check(WindowFilter.isSwitchable(role: "AXWindow", subrole: "AXStandardWindow"), "standard window passes")
    check(WindowFilter.isSwitchable(role: "AXWindow", subrole: "AXDialog"), "dialog passes")
    check(!WindowFilter.isSwitchable(role: "AXWindow", subrole: "AXFloatingWindow"), "palette is rejected")
    check(!WindowFilter.isSwitchable(role: "AXGroup", subrole: "AXStandardWindow"), "a window's child is rejected")
    check(!WindowFilter.isSwitchable(role: nil, subrole: nil), "unknown element is rejected")
}

// Arrangement
do {
    func window(_ id: UInt32, pid: Int32 = 1, app: String = "App", title: String = "") -> WindowFacts {
        WindowFacts(id: id, pid: pid, bundleID: "b\(pid)", title: title, appName: app)
    }
    func ids(_ windows: [WindowFacts], _ scope: WindowScope, _ context: ArrangementContext = ArrangementContext(),
             exceptions: [AppException] = []) -> [UInt32] {
        Arrangement.arrange(windows, scope: scope, exceptions: exceptions, context: context).map(\.id)
    }

    var context = ArrangementContext()
    context.recency = [3, 1, 2]
    check(ids([window(1), window(2), window(3)], WindowScope(), context) == [3, 1, 2], "recently focused order")

    var scope = WindowScope()
    scope.order = .recentlyCreated
    check(ids([window(1), window(3), window(2)], scope) == [3, 2, 1], "recently created order")

    scope = WindowScope()
    scope.order = .alphabetical
    check(ids([window(1, app: "b"), window(2, app: "A"), window(3, app: "c")], scope) == [2, 1, 3],
          "alphabetical ignores case")

    var a = window(1), b = window(2), c = window(3)
    a.spaceIDs = [20]; b.spaceIDs = [10]; c.spaceIDs = [10]
    context = ArrangementContext()
    context.spaceOrder = [10, 20]
    context.recency = [3, 2, 1]
    scope = WindowScope()
    scope.order = .space
    check(ids([a, b, c], scope, context) == [3, 2, 1], "space order, recency within a space")

    var minimized = window(1); minimized.isMinimized = true
    scope = WindowScope()
    context = ArrangementContext()
    context.recency = [1, 2]
    scope.minimized = .hide
    check(ids([minimized, window(2)], scope, context) == [2], "hide minimized")
    scope.minimized = .atEnd
    check(ids([minimized, window(2)], scope, context) == [2, 1], "minimized at the end")

    var hidden = window(1); hidden.isAppHidden = true
    var full = window(2); full.isFullscreen = true
    scope = WindowScope(); scope.hidden = .hide
    check(ids([hidden, window(3)], scope) == [3], "hide hidden apps")
    scope = WindowScope(); scope.fullscreen = .hide
    check(ids([full, window(3)], scope) == [3], "hide full screen windows")

    context = ArrangementContext()
    context.activePid = 1
    scope = WindowScope(); scope.apps = .active
    check(ids([window(1, pid: 1), window(2, pid: 2)], scope, context) == [1], "active app only")
    scope.apps = .nonActive
    check(ids([window(1, pid: 1), window(2, pid: 2)], scope, context) == [2], "everything but the active app")

    context = ArrangementContext()
    context.windowUnderCursor = 2
    context.pidUnderCursor = 2
    scope = WindowScope(); scope.apps = .underCursor
    check(ids([window(1, pid: 2), window(2, pid: 2)], scope, context) == [2], "window under cursor")
    scope.apps = .appUnderCursor
    check(Set(ids([window(1, pid: 2), window(2, pid: 2), window(3, pid: 3)], scope, context)) == [1, 2],
          "app under cursor")

    var elsewhere = window(1); elsewhere.isOnVisibleSpace = false
    scope = WindowScope(); scope.spaces = .visible
    check(ids([elsewhere, window(2)], scope) == [2], "visible Spaces only")
    scope.spaces = .nonVisible
    check(ids([elsewhere, window(2)], scope) == [1], "other Spaces only")

    var left = window(1); left.screenIndex = 0
    var right = window(2); right.screenIndex = 1
    context = ArrangementContext()
    context.switcherScreenIndex = 1
    scope = WindowScope(); scope.screens = .showingSwitcher
    check(ids([left, right], scope, context) == [2], "switcher's screen only")

    var tab = window(1); tab.isInactiveTab = true
    scope = WindowScope()
    check(ids([tab, window(2)], scope) == [2], "background tabs are merged by default")
    scope.tabs = .separateWindows
    check(Set(ids([tab, window(2)], scope)) == [1, 2], "background tabs can be shown")

    context = ArrangementContext()
    context.recency = [1, 2, 3]
    scope = WindowScope(); scope.grouping = .oneWindowPerApp
    check(ids([window(1, pid: 1), window(2, pid: 1), window(3, pid: 2)], scope, context) == [1, 3],
          "one window per app keeps the most recent")

    var empty = window(9, pid: 9); empty.isWindowless = true
    scope = WindowScope()
    check(ids([empty, window(1)], scope) == [1], "windowless apps are off by default")
    scope.windowlessApps = .atEnd
    check(ids([empty, window(1)], scope) == [1, 9], "windowless apps at the end")
    scope.spaces = .visible
    empty.isOnVisibleSpace = false
    check(ids([empty, window(1)], scope) == [1, 9], "Space filter doesn't drop windowless apps")

    let hideAll = AppException(bundleID: "b1", hide: .always)
    check(ids([window(1, pid: 1), window(2, pid: 2)], WindowScope(), exceptions: [hideAll]) == [2], "exception hides an app")
    var finder = window(9, pid: 1); finder.isWindowless = true
    scope = WindowScope(); scope.windowlessApps = .show
    let whenEmpty = AppException(bundleID: "b1", hide: .whenNoOpenWindow)
    check(ids([finder], scope, exceptions: [whenEmpty]).isEmpty, "exception hides a windowless app")
    check(ids([window(1, pid: 1)], scope, exceptions: [whenEmpty]) == [1], "that exception keeps real windows")
    let byTitle = AppException(bundleID: "b1", hide: .whenTitleContains, titleText: "SECRET")
    check(ids([window(1, pid: 1, title: "my secret doc"), window(2, pid: 1, title: "notes")], WindowScope(),
              exceptions: [byTitle]) == [2], "exception hides by title, ignoring case")
    check(AppException(bundleID: "com.parallels.").matches("com.parallels.desktop"), "trailing dot matches a prefix")
    check(!AppException(bundleID: "com.parallels").matches("com.parallels.desktop"), "no dot needs an exact match")

    var settings = Settings()
    settings.exceptions = [AppException(bundleID: "vm", ignore: .whenFullscreen), AppException(bundleID: "rd", ignore: .always)]
    check(settings.ignoresShortcuts(frontBundleID: "vm", isFullscreen: true), "ignored when full screen")
    check(!settings.ignoresShortcuts(frontBundleID: "vm", isFullscreen: false), "not ignored when windowed")
    check(settings.ignoresShortcuts(frontBundleID: "rd", isFullscreen: false), "always ignored")
    check(!settings.ignoresShortcuts(frontBundleID: nil, isFullscreen: true), "no front app ignores nothing")
}

// Search
do {
    let safari = WindowFacts(id: 1, pid: 1, title: "Apple", appName: "Safari")
    let notes = WindowFacts(id: 2, pid: 2, title: "Safety plan", appName: "Notes")
    let ids = { (q: String) in Arrangement.search([safari, notes], query: q).map(\.id) }
    check(ids("") == [1, 2], "empty search keeps everything")
    check(ids("safety") == [2], "search matches titles")
    check(ids("safe").first == 2, "an exact match outranks a loose one")
    check(ids("SAFARI") == [1], "search ignores case")
    check(ids("sfr") == [1], "search matches letters in order")
    check(ids("zzz").isEmpty, "search can match nothing")
    let exactFirst = Arrangement.search(
        [WindowFacts(id: 1, pid: 1, title: "n o t e s"), WindowFacts(id: 2, pid: 2, title: "notes")], query: "notes")
    check(exactFirst.map(\.id) == [2, 1], "contiguous matches come first")
}

// Settings
do {
    var s = Settings()
    s.keys.close = nil
    s.keys.previous = 50
    s.shortcuts.append(Shortcut(hold: [.control, .shift], keyCode: 49))
    s.style = .titles
    let data = try! JSONEncoder().encode(s)
    let back = try! JSONDecoder().decode(Settings.self, from: data)
    check(back == s, "settings survive saving")
    check(back.keys.close == nil, "an unassigned key stays unassigned")
    let partial = try! JSONDecoder().decode(Settings.self, from: Data(#"{"style":"appIcons"}"#.utf8))
    check(partial.style == .appIcons && partial.shortcuts.count == 2, "missing settings fall back to defaults")
    let keys = try! JSONDecoder().decode(SessionKeys.self, from: Data("{}".utf8))
    check(keys.close == KeyCode.w, "missing keys use defaults")
    let fresh = Settings()
    check(!fresh.fullScreenMenuBarButtons, "the full screen menu bar buttons start off")
    check(fresh.mouseHover, "hovering selects by default")
    check(fresh.showCloseButton && !fresh.showMinimizeButton && !fresh.showFullscreenButton, "only the X is on by default")
    let hidden = try! JSONDecoder().decode(Settings.self, from: Data(#"{"hideCircles":true}"#.utf8))
    check(!hidden.showCloseButton, "having hidden the buttons before keeps the X hidden")
    let shown = try! JSONDecoder().decode(Settings.self, from: Data(#"{"hideCircles":false}"#.utf8))
    check(shown.showCloseButton && !shown.showMinimizeButton, "an older install gets just the X")
    var picked = Settings()
    picked.showCloseButton = false
    picked.showFullscreenButton = true
    let pickedBack = try! JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(picked))
    check(!pickedBack.showCloseButton && pickedBack.showFullscreenButton, "button choices survive saving")
    var reverse = Settings()
    reverse.shortcuts = [Shortcut(hold: .option, keyCode: KeyCode.tab), Shortcut(hold: [.option, .shift], keyCode: KeyCode.tab)]
    check(!reverse.isReverseFree(for: reverse.shortcuts[0]), "an explicit shortcut takes priority over the shift variant")
    reverse.shortcuts.removeLast()
    check(reverse.isReverseFree(for: reverse.shortcuts[0]), "otherwise the shift variant is free")
    var clash = Settings()
    check(clash.conflictingShortcuts.isEmpty, "default shortcuts don't clash")
    clash.shortcuts[1] = clash.shortcuts[0]
    check(clash.conflictingShortcuts == [0, 1], "identical shortcuts clash")
}

// SwipeTracker
do {
    var t = SwipeTracker()
    func frame(_ x: Double, fingers: Int = 3, y: Double = 0.5, open: Bool = false, horizontal: Bool = true) -> SwipeTracker.Action {
        let touches = fingers >= 2 ? ["a": (x: x, y: y), "b": (x: x, y: y)] : [:]
        return t.handle(fingersDown: fingers, touches: touches, requiredFingers: 3, horizontal: horizontal, isOpen: open)
    }
    check(frame(0.5) == .none, "first frame sets the baseline")
    check(frame(0.51) == .none, "small moves don't trigger")
    check(frame(0.6) == .open(reversed: false), "swiping right opens")
    check(frame(0.7, open: true) == .step(.right), "further swiping steps")
    check(frame(0.7, open: true) == .none, "stopping doesn't step")
    check(frame(0.6, open: true) == .step(.left), "swiping back steps back")
    check(frame(0.6, fingers: 0, open: true) == .release, "lifting releases")

    t.reset()
    check(frame(0.5, fingers: 2) == .none, "wrong finger count is ignored")
    check(frame(0.9, fingers: 2) == .none, "wrong finger count never triggers")
    t.reset()
    _ = frame(0.5, y: 0.5)
    check(frame(0.6, y: 0.8) == .none, "a mostly vertical swipe doesn't trigger a sideways gesture")
    t.reset()
    _ = frame(0.5, y: 0.5, horizontal: false)
    check(frame(0.5, y: 0.4, horizontal: false) == .open(reversed: true), "swiping down opens reversed")
}

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
