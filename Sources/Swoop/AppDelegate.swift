import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let permissionPollInterval: TimeInterval = 2

    private var statusItem: NSStatusItem?
    private var statusText = "Starting"

    func applicationDidFinishLaunching(_ notification: Notification) {
        updateMenuBar()
        if CommandLine.arguments.contains("--open-settings") {
            SettingsWindowController.shared.present()
        }
        SettingsStore.shared.onChange = { [weak self] in
            Switcher.shared.applySettings()
            self?.updateMenuBar()
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            begin()
        } else {
            // Without this, ⌘Tab stays native rather than being replaced by nothing.
            setStatus("Waiting for Accessibility permission")
            Timer.scheduledTimer(
                withTimeInterval: Self.permissionPollInterval, repeats: true
            ) { [weak self] timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                self?.begin()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Switcher.shared.stop()
    }

    /// Opening Swoop again is the way back to Settings when the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.present()
        return true
    }

    private func begin() {
        Switcher.shared.start()
        setStatus("Running")
        // Previews are optional, so this is the only time Swoop asks. Denying it
        // leaves app icons on the tiles.
        let askedKey = "askedForScreenRecording"
        if !UserDefaults.standard.bool(forKey: askedKey) {
            UserDefaults.standard.set(true, forKey: askedKey)
            CGRequestScreenCaptureAccess()
        }
    }

    private func setStatus(_ text: String) {
        statusText = text
        updateMenuBar()
    }

    private func updateMenuBar() {
        guard SettingsStore.shared.settings.menuBarIconShown else {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }
        let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "Swoop")
        statusItem = item

        let menu = NSMenu()
        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit Swoop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        item.menu = menu
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.present()
    }
}
