// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Swoop",
    platforms: [.macOS(.v13)],
    targets: [
        // Pure, AppKit-free switcher logic (unit-testable).
        .target(name: "SwoopCore"),
        // Objective-C, because Swift can't catch the exceptions NSTouch can throw.
        .target(name: "SwoopObjC"),
        // The AppKit menu-bar application.
        .executableTarget(
            name: "Swoop",
            dependencies: ["SwoopCore", "SwoopObjC"]
        ),
        // Restores native ⌘Tab if Swoop ends without doing it itself. A separate program,
        // because a crashing process can't be relied on to clean up after itself.
        .executableTarget(name: "SwoopWatchdog"),
        // Headless verification, run as a plain program:
        //   swift run SwoopCoreCheck
        .executableTarget(
            name: "SwoopCoreCheck",
            dependencies: ["SwoopCore"]
        ),
    ]
)
