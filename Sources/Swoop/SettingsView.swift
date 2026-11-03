import AppKit
import SwoopCore
import ServiceManagement
import SwiftUI

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Swoop Settings"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 560, height: 460)
        window.contentView = NSHostingView(rootView: SettingsView().environmentObject(SettingsStore.shared))
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            ShortcutsTab().tabItem { Text("Shortcuts") }
            KeysTab().tabItem { Text("Controls") }
            AppearanceTab().tabItem { Text("Appearance") }
            FullScreenTab().tabItem { Text("Full Screen") }
            ExceptionsTab().tabItem { Text("Exceptions") }
            GeneralTab().tabItem { Text("General") }
        }
        .padding(8)
    }
}

private struct Note: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private struct OptionPicker<Option: SettingOption>: View {
    let title: String
    @Binding var selection: Option

    init(_ title: String, _ selection: Binding<Option>) {
        self.title = title
        _selection = selection
    }

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(Array(Option.allCases)) { Text($0.label).tag($0) }
        }
    }
}

/// Click, then press a key. Swoop's own shortcuts are paused so they don't fire instead.
private struct KeyRecorder: View {
    @Binding var keyCode: Int?
    var canClear = true

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 4) {
            Button(isRecording ? "Press a key…" : KeyNames.name(keyCode)) {
                isRecording ? stop() : start()
            }
            .frame(minWidth: 90)
            if canClear && keyCode != nil && !isRecording {
                Button {
                    keyCode = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Unassign")
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        isRecording = true
        Switcher.shared.setHotkeysPaused(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            keyCode = Int(event.keyCode)
            stop()
            return nil
        }
    }

    private func stop() {
        guard isRecording else { return }
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        Switcher.shared.setHotkeysPaused(false)
    }
}

private extension Binding where Value == Int {
    var optional: Binding<Int?> {
        Binding<Int?>(get: { wrappedValue }, set: { if let value = $0 { wrappedValue = value } })
    }
}

private struct ScopeSection: View {
    @Binding var scope: WindowScope

    var body: some View {
        OptionPicker("Apps", $scope.apps)
        OptionPicker("Spaces", $scope.spaces)
        OptionPicker("Screens", $scope.screens)
        OptionPicker("Minimized windows", $scope.minimized)
        OptionPicker("Hidden apps", $scope.hidden)
        OptionPicker("Full screen windows", $scope.fullscreen)
        OptionPicker("Apps with no windows", $scope.windowlessApps)
        OptionPicker("Order", $scope.order)
        OptionPicker("Show", $scope.grouping)
        OptionPicker("Tabs", $scope.tabs)
        OptionPicker("On release", $scope.onRelease)
    }
}

private struct ShortcutsTab: View {
    @EnvironmentObject var store: SettingsStore

    var body: some View {
        Form {
            let conflicts = store.settings.conflictingShortcuts
            ForEach(Array(store.settings.shortcuts.enumerated()), id: \.element.id) { index, _ in
                Section {
                    ShortcutEditor(shortcut: $store.settings.shortcuts[index])
                    if conflicts.contains(index) {
                        Label("Another shortcut uses these keys, so only one of them will work.",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    if store.settings.shortcuts.count > 1 {
                        Button("Remove This Shortcut", role: .destructive) {
                            store.settings.shortcuts.remove(at: index)
                        }
                    }
                } header: {
                    Text("Shortcut \(index + 1)")
                }
            }
            Section {
                Button("Add Shortcut") {
                    store.settings.shortcuts.append(
                        Shortcut(hold: .option, keyCode: KeyCode.grave, scope: {
                            var scope = WindowScope()
                            scope.apps = .active
                            return scope
                        }()))
                }
                .disabled(store.settings.shortcuts.count >= Settings.maxShortcuts)
            }
            Section("Trackpad") {
                OptionPicker("Swipe to open", $store.settings.gesture)
                if store.settings.gesture != .disabled {
                    Note("Turn off any macOS gesture using the same swipe, in System Settings > Trackpad > More Gestures.")
                    Toggle("Haptic feedback", isOn: $store.settings.gestureHaptics)
                    ScopeSection(scope: $store.settings.gestureScope)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutEditor: View {
    @Binding var shortcut: Shortcut

    private func toggle(_ title: String, _ modifier: Modifiers) -> some View {
        Toggle(title, isOn: Binding(
            get: { shortcut.hold.contains(modifier) },
            set: { isOn in
                if isOn { shortcut.hold.insert(modifier) } else { shortcut.hold.remove(modifier) }
            }))
        .toggleStyle(.button)
    }

    var body: some View {
        LabeledContent("Hold") {
            HStack(spacing: 4) {
                toggle("⌘", .command)
                toggle("⌥", .option)
                toggle("⌃", .control)
                toggle("⇧", .shift)
            }
        }
        LabeledContent("Then press") {
            KeyRecorder(keyCode: $shortcut.keyCode.optional, canClear: false)
        }
        if shortcut.hold.isEmpty {
            Note("With nothing to hold, the switcher stays open until you choose a window, and this key won't type anything in other apps.")
        }
        ScopeSection(scope: $shortcut.scope)
    }
}

private struct KeysTab: View {
    @EnvironmentObject var store: SettingsStore

    private func row(_ title: String, _ keyPath: WritableKeyPath<SessionKeys, Int?>) -> some View {
        LabeledContent(title) {
            KeyRecorder(keyCode: Binding(
                get: { store.settings.keys[keyPath: keyPath] },
                set: { store.settings.keys[keyPath: keyPath] = $0 }))
        }
    }

    var body: some View {
        Form {
            Section("While the switcher is open") {
                row("Switch to the selected window", \.focus)
                row("Select the previous window", \.previous)
                row("Cancel", \.cancel)
                row("Close window", \.close)
                row("Minimize or restore window", \.minimize)
                row("Toggle full screen", \.fullscreen)
                row("Quit app", \.quit)
                row("Hide or show app", \.hide)
                row("Search", \.search)
            }
            Section("Navigation") {
                Toggle("Arrow keys", isOn: $store.settings.arrowKeys)
                Toggle("Vim keys (H, J, K, L)", isOn: $store.settings.vimKeys)
                if store.settings.vimKeys && store.settings.keys.hide == KeyCode.h {
                    Note("H now moves left, so Hide or show app needs a different key.")
                }
                Toggle("Select the window under the mouse", isOn: $store.settings.mouseHover)
                OptionPicker("Move the cursor to the chosen window", $store.settings.cursorFollow)
            }
            Section {
                Button("Restore Default Keys") { store.settings.keys = SessionKeys() }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AppearanceTab: View {
    @EnvironmentObject var store: SettingsStore

    var body: some View {
        Form {
            Section("Layout") {
                OptionPicker("Style", $store.settings.style)
                OptionPicker("Size", $store.settings.size)
                OptionPicker("Theme", $store.settings.theme)
                OptionPicker("Show on", $store.settings.showOnScreen)
            }
            Section("Titles") {
                OptionPicker("Show", $store.settings.titleContent)
                OptionPicker("Shorten long titles at the", $store.settings.titleTruncation)
            }
            Section("Tiles") {
                Toggle("Hide previews", isOn: $store.settings.hideThumbnails)
                Toggle("Hide status icons", isOn: $store.settings.hideStatusIcons)
                Toggle("Hide Space numbers", isOn: $store.settings.hideSpaceNumbers)
            }
            Section("Buttons on tiles") {
                Toggle("Close (X)", isOn: $store.settings.showCloseButton)
                Toggle("Minimize", isOn: $store.settings.showMinimizeButton)
                Toggle("Full screen", isOn: $store.settings.showFullscreenButton)
            }
            Section("Behavior") {
                Toggle("Show the selected window at full size", isOn: $store.settings.previewSelected)
                Toggle("Fade out when closing", isOn: $store.settings.fadeOut)
                LabeledContent("Delay before showing") {
                    HStack {
                        Slider(value: Binding(
                            get: { Double(store.settings.showDelayMs) },
                            set: { store.settings.showDelayMs = Int($0) }
                        ), in: 0...500, step: 10)
                        Text("\(store.settings.showDelayMs) ms")
                            .monospacedDigit()
                            .frame(width: 60, alignment: .trailing)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct FullScreenTab: View {
    @EnvironmentObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle("Show window buttons in the menu bar", isOn: $store.settings.fullScreenMenuBarButtons)
                Note("While the front window is in full screen, the red, yellow and green buttons appear beside your menu bar icons.")
                Note("Yellow leaves full screen first, because macOS can't minimize a full screen window.")
                Note("macOS can hide menu bar icons behind the notch when an app has a lot of menus.")
            }
            Section {
                Toggle("Skip the animation when switching Spaces", isOn: $store.settings.instantSpaceSwitching)
                    .disabled(!InstantSpaces.isSupported)
                Note("Switches to a window on another Space or in full screen straight away, using a fake trackpad swipe. Turn this off if the screen ever goes black or lands on the wrong Space.")
                if !InstantSpaces.isSupported {
                    Note("This needs macOS 27 or later.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ExceptionsTab: View {
    @EnvironmentObject var store: SettingsStore

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    var body: some View {
        Form {
            Section {
                ForEach($store.settings.exceptions) { $exception in
                    VStack(alignment: .leading) {
                        HStack {
                            TextField("Bundle ID", text: $exception.bundleID)
                            Button {
                                store.settings.exceptions.removeAll { $0.id == exception.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove")
                        }
                        OptionPicker("In the switcher", $exception.hide)
                        if exception.hide == .whenTitleContains {
                            TextField("Text in the title", text: $exception.titleText)
                        }
                        OptionPicker("While it's frontmost", $exception.ignore)
                    }
                }
            } header: {
                Text("A bundle ID ending in “.” matches every app starting with it.")
            }
            Section {
                Menu("Add Running App") {
                    ForEach(runningApps, id: \.processIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier ?? "") {
                            store.settings.exceptions.append(AppException(bundleID: app.bundleIdentifier ?? ""))
                        }
                    }
                }
                Button("Add by Bundle ID") {
                    store.settings.exceptions.append(AppException(bundleID: ""))
                }
                Button("Restore Default Exceptions") {
                    store.settings.exceptions = Settings.defaultExceptions
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct GeneralTab: View {
    @EnvironmentObject var store: SettingsStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { wanted in
                        do {
                            if wanted {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            NSLog("Swoop: couldn't change the login item: \(error)")
                        }
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }))
                Toggle("Show menu bar icon", isOn: $store.settings.menuBarIconShown)
                if !store.settings.menuBarIconShown {
                    Note("To get back here, open Swoop again from Applications.")
                }
            }
            Section("Permissions") {
                LabeledContent("Accessibility", value: AXIsProcessTrusted() ? "Allowed" : "Not allowed")
                LabeledContent("Screen Recording", value: CGPreflightScreenCaptureAccess() ? "Allowed" : "Not allowed")
                if !CGPreflightScreenCaptureAccess() {
                    Note("Without this, tiles show app icons instead of previews. Reopen Swoop after allowing it.")
                    Button("Open Screen Recording Settings") {
                        CGRequestScreenCaptureAccess()
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
            Section {
                Button("Restore All Settings to Defaults", role: .destructive) {
                    store.settings = Settings()
                }
            }
        }
        .formStyle(.grouped)
    }
}
