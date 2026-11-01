import CoreGraphics
import Darwin
import Foundation

// Waits for Swoop to end, then turns native ⌘Tab back on. Usage: SwoopWatchdog <pid>

guard CommandLine.arguments.count > 1, let parent = pid_t(CommandLine.arguments[1]) else { exit(1) }

/// A new copy of Swoop may already have taken ⌘Tab over, and that has to stand.
func anotherSwoopIsRunning() -> Bool {
    let pgrep = Process()
    pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    pgrep.arguments = ["-x", "Swoop"]
    pgrep.standardOutput = FileHandle.nullDevice
    guard (try? pgrep.run()) != nil else { return false }
    pgrep.waitUntilExit()
    return pgrep.terminationStatus == 0
}

func restoreAndExit() -> Never {
    if !anotherSwoopIsRunning() {
        typealias SetSymbolicHotKeyFn = @convention(c) (Int32, Bool) -> CGError
        let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        if let pointer = dlsym(skyLight, "CGSSetSymbolicHotKeyEnabled") {
            let setSymbolicHotKey = unsafeBitCast(pointer, to: SetSymbolicHotKeyFn.self)
            _ = setSymbolicHotKey(1, true)
            _ = setSymbolicHotKey(2, true)
        }
    }
    exit(0)
}

let source = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
source.setEventHandler { restoreAndExit() }
source.resume()
// Swoop may have ended before the watch began, and then the event would never come.
if kill(parent, 0) != 0 { restoreAndExit() }
dispatchMain()
