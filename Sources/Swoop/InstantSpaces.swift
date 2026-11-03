// The swipe events here are ported from InstantSpaceSwitcher:
// https://github.com/jurplel/InstantSpaceSwitcher
//
// MIT License
//
// Copyright (c) 2026 jurplel
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import AppKit
import ApplicationServices
import Darwin

/// Skips the animation between Spaces by sending the Dock a very fast fake trackpad swipe.
/// macOS has no call for this, and these events are undocumented, so anything unexpected
/// returns false and the caller goes the normal way, with the animation.
enum InstantSpaces {
    /// How long a jump takes, per Space crossed. Measured at about 70ms on macOS 27.
    static let durationPerSpace: TimeInterval = 0.15
    /// What the Dock expects changed in macOS 27, and earlier versions need different
    /// events that haven't been tried here.
    static let isSupported = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27

    private static let eventType: UInt32 = 55
    private static let gestureHIDType: UInt32 = 110
    private static let swipeMotion: UInt32 = 123
    private static let swipeProgress: UInt32 = 124
    private static let swipePositionX: UInt32 = 125
    private static let swipePositionY: UInt32 = 126
    private static let swipeMask: UInt32 = 115
    private static let swipeVelocityX: UInt32 = 129
    private static let swipeVelocityY: UInt32 = 130
    private static let gesturePhase: UInt32 = 132
    private static let gesturePhaseAlias: UInt32 = 134
    private static let zoomDeltaY: UInt32 = 138
    private static let timestampAlias: UInt32 = 169

    private static let gestureEvent: Int64 = 29
    private static let dockControlEvent: Int64 = 30
    private static let dockSwipe: Int64 = 23
    private static let horizontal: Int64 = 1

    private enum Phase: Int64 {
        case began = 1, changed = 2, ended = 4
    }

    /// The smallest value the payload can hold, which leaves nothing to animate.
    private static let progress = 0.000016
    /// Commits the switch. The payload's fixed point format tops out around 32767.
    private static let flingVelocity = 9999.0

    /// How many Spaces to cross, and which way, to reach `target` on the display under the
    /// pointer, which is the one a swipe acts on. Nil if it isn't on that display.
    static func route(to target: UInt64) -> (steps: Int, right: Bool)? {
        guard let display = PrivateAPI.spaceDisplay(underPointer: NSEvent.mouseLocation),
              let from = display.ordered.firstIndex(of: display.current),
              let to = display.ordered.firstIndex(of: target),
              from != to
        else { return nil }
        return (abs(to - from), to > from)
    }

    /// One swipe per Space. A swipe past the last Space can leave the Dock showing a black
    /// screen until it times out, so `route` must be from the Space actually showing.
    static func jump(steps: Int, right: Bool) -> Bool {
        for _ in 0..<steps {
            for phase in [Phase.began, .changed, .ended] {
                guard post(phase, right: right) else { return false }
            }
        }
        return true
    }

    private static func post(_ phase: Phase, right: Bool) -> Bool {
        let sign = swipeSign(right: right)
        guard let event = CGEvent(source: nil), let companion = CGEvent(source: nil) else { return false }
        set(event, eventType, dockControlEvent)
        set(event, gestureHIDType, dockSwipe)
        set(event, gesturePhase, phase.rawValue)
        set(event, swipeMotion, horizontal)
        set(event, swipeProgress, sign * progress)
        set(event, gesturePhaseAlias, phase.rawValue)
        set(event, zoomDeltaY, 3.0)
        set(event, timestampAlias, Double(mach_absolute_time()))
        set(event, swipePositionX, 0.1)
        if phase == .ended { set(event, swipeVelocityX, sign * flingVelocity) }
        guard let augmented = withPayload(event) else { return false }

        // The Dock ignores the swipe without an empty gesture event following it.
        set(companion, eventType, gestureEvent)
        augmented.post(tap: .cgSessionEventTap)
        companion.post(tap: .cgSessionEventTap)
        return true
    }

    /// Right is negative, and the Dock reads the sign through the natural scrolling setting.
    private static func swipeSign(right: Bool) -> Double {
        let name = "com.apple.swipescrolldirection" as CFString
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        var isSet: DarwinBoolean = false
        let natural = CFPreferencesGetAppBooleanValue(name, kCFPreferencesAnyApplication, &isSet)
        let sign = right ? -1.0 : 1.0
        return !isSet.boolValue || natural ? sign : -sign
    }

    private static func set(_ event: CGEvent, _ field: UInt32, _ value: Int64) {
        event.setIntegerValueField(unsafeBitCast(field, to: CGEventField.self), value: value)
    }

    private static func set(_ event: CGEvent, _ field: UInt32, _ value: Double) {
        event.setDoubleValueField(unsafeBitCast(field, to: CGEventField.self), value: value)
    }

    private static func integer(_ event: CGEvent, _ field: UInt32) -> Int64 {
        event.getIntegerValueField(unsafeBitCast(field, to: CGEventField.self))
    }

    private static func double(_ event: CGEvent, _ field: UInt32) -> Double {
        event.getDoubleValueField(unsafeBitCast(field, to: CGEventField.self))
    }

    /// macOS 27's Dock reads the swipe from a binary payload added to the serialized event.
    private static func withPayload(_ event: CGEvent) -> CGEvent? {
        guard let data = event.data as Data?, data.starts(with: [0, 0, 0, 2]) else { return nil }
        let payload = makePayload(event)
        guard payload.count <= Int(UInt16.max) else { return nil }
        var result = data
        let fieldID: UInt16 = 4205
        result.append(contentsOf: [
            UInt8(payload.count >> 8), UInt8(payload.count & 0xFF),
            UInt8(fieldID >> 8), UInt8(fieldID & 0xFF),
        ])
        result.append(payload)
        return CGEvent(withDataAllocator: nil, data: result as CFData)
    }

    private static func makePayload(_ event: CGEvent) -> Data {
        let phase = integer(event, gesturePhase)
        let velocityX = double(event, swipeVelocityX)
        let velocityY = double(event, swipeVelocityY)
        let hasVelocity = velocityX != 0 || velocityY != 0 || phase == Phase.ended.rawValue
        let fluidSize: UInt32 = 40
        let velocitySize: UInt32 = 28
        let fluidType: UInt32 = 23
        let velocityType: UInt32 = 9
        let dockPrimaryFlavor: UInt16 = 3

        var data = Data()
        func add<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func addEventBase(size: UInt32, type: UInt32, options: UInt32, depth: UInt32) {
            add(size)
            add(type)
            add(options)
            add(depth) // One byte of depth and three reserved.
        }

        // Header
        add(event.timestamp == 0 ? mach_absolute_time() : event.timestamp)
        add(UInt64(0)) // sender
        add(UInt32(0)) // options
        add(UInt32(0)) // attribute length
        add(UInt32(hasVelocity ? 2 : 1))

        // The gesture
        addEventBase(size: fluidSize, type: fluidType, options: UInt32((phase & 0xFF) << 24), depth: 0)
        add(fixedPoint(double(event, swipePositionX)))
        add(fixedPoint(double(event, swipePositionY)))
        add(Int32(0))
        add(UInt32(truncatingIfNeeded: integer(event, swipeMask)))
        add(UInt16(truncatingIfNeeded: integer(event, swipeMotion)))
        add(dockPrimaryFlavor)
        add(fixedPoint(double(event, swipeProgress)))

        if hasVelocity {
            addEventBase(size: velocitySize, type: velocityType, options: 0, depth: 1)
            add(fixedPoint(velocityX))
            add(fixedPoint(velocityY))
            add(Int32(0))
        }
        return data
    }

    /// 16.16 fixed point, keeping anything nonzero from rounding away.
    private static func fixedPoint(_ value: Double) -> Int32 {
        let fixed = Int32(value * 65536)
        if fixed == 0, value != 0 { return value > 0 ? 1 : -1 }
        return fixed
    }
}
