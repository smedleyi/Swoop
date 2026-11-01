import AppKit
import SwoopCore
import SwoopObjC

/// Trackpad swipes. Detection uses a listen-only tap, because AltTab found an
/// active tap on gesture events adds lag to the cursor. The active tap, which
/// stops the app behind from also reacting, only runs once enough fingers are down.
final class GestureMonitor {
    static let shared = GestureMonitor()

    var onAction: ((SwipeTracker.Action) -> Void)?
    var isSwitcherOpen: (() -> Bool)?

    private var gesture = Gesture.disabled
    private var tracker = SwipeTracker()
    private var absorbTap: CFMachPort?
    private var detectTap: CFMachPort?
    private var isAbsorbing = false
    private var absorbEvents = false

    private var gestureEventRaw: UInt32 { UInt32(NSEvent.EventType.gesture.rawValue) }

    func update(_ gesture: Gesture) {
        self.gesture = gesture
        let enabled = gesture != .disabled
        if enabled && detectTap == nil { createTaps() }
        if let detectTap { CGEvent.tapEnable(tap: detectTap, enable: enabled) }
        if !enabled { setAbsorbing(false) }
        tracker.reset()
    }

    private func createTaps() {
        let mask = CGEventMask(NSEvent.EventTypeMask.gesture.rawValue)
        // The tap created last sees events first, and detection has to run before
        // the absorbing tap decides.
        absorbTap = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in GestureMonitor.shared.absorb(type: type, event: event) },
            userInfo: nil)
        detectTap = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in GestureMonitor.shared.detect(type: type, event: event) },
            userInfo: nil)
        for port in [absorbTap, detectTap].compactMap({ $0 }) {
            CFRunLoopAddSource(
                CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        }
        if let absorbTap { CGEvent.tapEnable(tap: absorbTap, enable: false) }
    }

    private func setAbsorbing(_ absorbing: Bool) {
        guard absorbing != isAbsorbing, let absorbTap else { return }
        isAbsorbing = absorbing
        CGEvent.tapEnable(tap: absorbTap, enable: absorbing)
        if !absorbing { absorbEvents = false }
    }

    private func absorb(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if isAbsorbing, let absorbTap { CGEvent.tapEnable(tap: absorbTap, enable: true) }
        } else if type.rawValue == gestureEventRaw, absorbEvents {
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    private func detect(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if gesture != .disabled, let detectTap { CGEvent.tapEnable(tap: detectTap, enable: true) }
        } else if type.rawValue == gestureEventRaw {
            handle(event)
        }
        return Unmanaged.passUnretained(event)
    }

    private func handle(_ event: CGEvent) {
        guard let nsEvent = NSEvent(cgEvent: event) else { return }
        // Touch Bar and touchscreen touches don't have trackpad positions.
        let all = nsEvent.allTouches().filter { $0.type == .indirect }
        // macOS often sends empty events between real ones.
        guard !all.isEmpty else { return }

        let down = all.filter { $0.phase == .began || $0.phase == .moved || $0.phase == .stationary }
        let isOpen = isSwitcherOpen?() ?? false
        setAbsorbing(isOpen || down.count >= gesture.fingers)
        // Too few fingers to be a swipe, which covers ordinary pointing and scrolling.
        if !isOpen && down.count < gesture.fingers {
            tracker.reset()
            absorbEvents = false
            return
        }

        var moving = [String: (x: Double, y: Double)]()
        for touch in all where touch.phase == .began || touch.phase == .moved {
            var point = NSPoint.zero
            if SwoopTouchPosition(touch, &point) {
                moving["\(touch.identity)"] = (Double(point.x), Double(point.y))
            }
        }

        let action = tracker.handle(
            fingersDown: down.count, touches: moving, requiredFingers: gesture.fingers,
            horizontal: gesture.isHorizontal, isOpen: isOpen)
        absorbEvents = isOpen || action != .none
        if action != .none { onAction?(action) }
    }
}
