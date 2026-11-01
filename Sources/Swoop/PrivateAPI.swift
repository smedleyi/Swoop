import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

/// macOS has no public API for moving focus to a specific window of another
/// app, seeing other Spaces' windows, or freeing up ⌘Tab. These are the private
/// calls window managers use, looked up at runtime so that a future macOS
/// removing one degrades that feature instead of stopping the app launching.
enum PrivateAPI {
    private static let skyLight = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)

    private enum Symbol: String, CaseIterable {
        case mainConnection = "CGSMainConnectionID"
        case capture = "CGSHWCaptureWindowList"
        case setSymbolicHotKey = "CGSSetSymbolicHotKeyEnabled"
        case setFrontProcess = "_SLPSSetFrontProcessWithOptions"
        case postEventRecord = "SLPSPostEventRecordTo"
        case getWindow = "_AXUIElementGetWindow"
        case remoteToken = "_AXUIElementCreateWithRemoteToken"
        case processForPid = "GetProcessForPID"
        case copySpaces = "CGSCopySpacesForWindows"
        case copyDisplaySpaces = "CGSCopyManagedDisplaySpaces"

        var pointer: UnsafeMutableRawPointer? {
            dlsym(skyLight, rawValue) ?? dlsym(defaultHandle, rawValue)
        }
    }

    private static func symbol<T>(_ symbol: Symbol, as type: T.Type) -> T? {
        symbol.pointer.map { unsafeBitCast($0, to: type) }
    }

    private typealias MainConnectionFn = @convention(c) () -> UInt32
    private typealias CaptureFn = @convention(c) (
        UInt32, UnsafeMutablePointer<CGWindowID>, UInt32, UInt32
    ) -> Unmanaged<CFArray>?
    private typealias SetSymbolicHotKeyFn = @convention(c) (Int32, Bool) -> CGError
    private typealias SetFrontProcessFn = @convention(c) (
        UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32
    ) -> CGError
    private typealias PostEventRecordFn = @convention(c) (
        UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>
    ) -> CGError
    private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias RemoteTokenFn = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
    private typealias ProcessForPidFn = @convention(c) (
        pid_t, UnsafeMutablePointer<ProcessSerialNumber>
    ) -> OSStatus

    private static let mainConnection = symbol(.mainConnection, as: MainConnectionFn.self)
    private static let capture = symbol(.capture, as: CaptureFn.self)
    private static let setSymbolicHotKey = symbol(.setSymbolicHotKey, as: SetSymbolicHotKeyFn.self)
    private static let setFrontProcess = symbol(.setFrontProcess, as: SetFrontProcessFn.self)
    private static let postEventRecord = symbol(.postEventRecord, as: PostEventRecordFn.self)
    private static let getWindow = symbol(.getWindow, as: GetWindowFn.self)
    private static let remoteToken = symbol(.remoteToken, as: RemoteTokenFn.self)
    private static let processForPid = symbol(.processForPid, as: ProcessForPidFn.self)
    private typealias CopySpacesFn = @convention(c) (UInt32, UInt32, CFArray) -> Unmanaged<CFArray>?
    private typealias CopyDisplaySpacesFn = @convention(c) (UInt32) -> Unmanaged<CFArray>?
    private static let copySpaces = symbol(.copySpaces, as: CopySpacesFn.self)
    private static let copyDisplaySpaces = symbol(.copyDisplaySpaces, as: CopyDisplaySpacesFn.self)

    static var missingSymbols: [String] {
        Symbol.allCases.filter { $0.pointer == nil }.map(\.rawValue)
    }

    // MARK: - ⌘Tab

    /// The Dock claims ⌘Tab (id 1) and ⌘⇧Tab (id 2) ahead of any app's hotkey, so a
    /// shortcut using one has to switch it off. That outlives the process, which is
    /// what the SwoopWatchdog target is for.
    static func setNativeSwitching(commandTab: Bool, commandShiftTab: Bool) {
        _ = setSymbolicHotKey?(1, commandTab)
        _ = setSymbolicHotKey?(2, commandShiftTab)
    }

    // MARK: - Windows

    static func windowID(of element: AXUIElement) -> CGWindowID? {
        var id = CGWindowID(0)
        guard let getWindow, getWindow(element, &id) == .success, id != 0 else { return nil }
        return id
    }

    /// Calls `body` with candidate elements of `pid` until it returns true or the
    /// time runs out. Apps leave windows on other Spaces out of their Accessibility
    /// window list, and building elements from a token is the only way to reach them.
    /// The token is the pid, a zero, the magic "coco", then the element's ID.
    static func scanElements(pid: pid_t, budget: TimeInterval, _ body: (AXUIElement) -> Bool) {
        guard let remoteToken else { return }
        var bytes = [UInt8](repeating: 0, count: 20)
        withUnsafeBytes(of: pid) { bytes.replaceSubrange(0..<4, with: $0) }
        withUnsafeBytes(of: Int32(0x636f_636f)) { bytes.replaceSubrange(8..<12, with: $0) }
        let deadline = Date().addingTimeInterval(budget)
        var id: UInt64 = 0
        while Date() < deadline {
            withUnsafeBytes(of: id) { bytes.replaceSubrange(12..<20, with: $0) }
            let token = Data(bytes) as CFData
            if let element = remoteToken(token)?.takeRetainedValue(), body(element) { return }
            id += 1
        }
    }

    /// Captures a window even when it's minimized or on another Space.
    static func captureWindow(_ id: CGWindowID) -> CGImage? {
        guard let capture, let mainConnection else { return nil }
        var id = id
        // ignoreGlobalClipShape (1 << 11) | bestResolution (1 << 8) | fullSize (1 << 19)
        let options: UInt32 = 1 << 11 | 1 << 8 | 1 << 19
        guard let images = capture(mainConnection(), &id, 1, options)?.takeRetainedValue() else { return nil }
        return (images as? [CGImage])?.first
    }

    // MARK: - Spaces

    /// The Spaces a window is on. Background tabs aren't on any. Nil means it couldn't be read.
    static func spaces(of id: CGWindowID) -> [UInt64]? {
        guard let copySpaces, let mainConnection else { return nil }
        // 7: current, other and user Spaces.
        let ids = [NSNumber(value: id)] as CFArray
        guard let result = copySpaces(mainConnection(), 7, ids)?.takeRetainedValue() else { return nil }
        return (result as? [NSNumber])?.map(\.uint64Value)
    }

    /// Every Space left to right, and the one showing on each display.
    static func spaceLayout() -> (ordered: [UInt64], visible: Set<UInt64>) {
        guard let copyDisplaySpaces, let mainConnection,
              let displays = copyDisplaySpaces(mainConnection())?.takeRetainedValue() as? [[String: Any]]
        else { return ([], []) }
        var ordered = [UInt64]()
        var visible = Set<UInt64>()
        for display in displays {
            if let current = (display["Current Space"] as? [String: Any])?["id64"] as? NSNumber {
                visible.insert(current.uint64Value)
            }
            for space in display["Spaces"] as? [[String: Any]] ?? [] {
                if let id = space["id64"] as? NSNumber { ordered.append(id.uint64Value) }
            }
        }
        return (ordered, visible)
    }

    // MARK: - Focus

    /// Brings one window of another app to the front, leaving its other windows
    /// where they are. Public APIs can only activate the whole app.
    static func focus(pid: pid_t, windowID: CGWindowID) {
        guard let processForPid, let setFrontProcess, let postEventRecord else { return }
        var psn = ProcessSerialNumber()
        guard processForPid(pid, &psn) == noErr else { return }
        // 0x200: mark the switch as user-initiated, so macOS doesn't suppress it.
        _ = setFrontProcess(&psn, windowID, 0x200)
        makeKey(windowID, psn: &psn, post: postEventRecord)
    }

    /// Makes the window key with a synthetic mouse-down, addressed to the window by
    /// ID. Only the down is sent, and the point is far past its bottom-right corner:
    /// AltTab's history shows a full click, or a point near the frame, can press
    /// buttons or (on macOS 27) resize the window.
    private static func makeKey(
        _ windowID: CGWindowID, psn: inout ProcessSerialNumber, post: PostEventRecordFn
    ) {
        var bytes = [UInt8](repeating: 0, count: 0x100)
        bytes[0x04] = 0xf8 // record length
        bytes[0x08] = 0x01 // left mouse down
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: windowID) { bytes.replaceSubrange(0x3c..<0x40, with: $0) }
        let point = CGPoint(x: 300_000, y: 300_000)
        withUnsafeBytes(of: point) { bytes.replaceSubrange(0x20..<0x30, with: $0) }
        _ = post(&psn, &bytes)
    }
}
