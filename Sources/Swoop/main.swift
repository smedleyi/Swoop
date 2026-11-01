import AppKit
import ServiceManagement

// `Swoop --check` reports what this Mac supports without touching the keyboard,
// for confirming a new macOS hasn't removed anything.
if CommandLine.arguments.contains("--check") {
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    print("Swoop \(version ?? "debug build")")
    let missing = PrivateAPI.missingSymbols
    print(missing.isEmpty ? "Private APIs: all found" : "Private APIs missing: \(missing.joined(separator: ", "))")
    print("Accessibility: \(AXIsProcessTrusted())")
    print("Screen Recording: \(CGPreflightScreenCaptureAccess())")
    WindowList.shared.printCheck()
    exit(missing.isEmpty ? 0 : 1)
}

// For turning Launch at Login on from a script, which needs to run from inside the app.
if CommandLine.arguments.contains("--enable-launch-at-login") {
    try? SMAppService.mainApp.register()
    print("Launch at Login enabled: \(SMAppService.mainApp.status == .enabled)")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
