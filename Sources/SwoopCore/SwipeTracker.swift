/// Turns trackpad finger positions into switcher actions. Positions are fractions
/// of the trackpad surface, with y increasing upward.
public struct SwipeTracker {
    public enum Direction: Equatable { case left, right, up, down }

    public enum Action: Equatable {
        case none
        case open(reversed: Bool)
        case step(Direction)
        case release
    }

    public static let threshold = 0.03

    private var baseline = [String: (x: Double, y: Double)]()

    public init() {}

    public mutating func reset() {
        baseline = [:]
    }

    /// `touches` holds fingers that are currently moving, while `fingersDown` also counts still ones.
    public mutating func handle(
        fingersDown: Int, touches: [String: (x: Double, y: Double)], requiredFingers: Int,
        horizontal: Bool, isOpen: Bool
    ) -> Action {
        if isOpen {
            // Lifting all but a resting finger counts as letting go.
            if fingersDown <= 1 {
                reset()
                return .release
            }
        } else if fingersDown != requiredFingers {
            reset()
            return .none
        }

        guard !touches.isEmpty else { return .none }
        var dx = 0.0, dy = 0.0
        for (id, position) in touches {
            let start = baseline[id] ?? position
            baseline[id] = start
            dx += (position.x - start.x) / Double(touches.count)
            dy += (position.y - start.y) / Double(touches.count)
        }

        if isOpen {
            let isHorizontal = abs(dx) >= abs(dy)
            guard max(abs(dx), abs(dy)) > Self.threshold else { return .none }
            rebase(touches)
            if isHorizontal { return .step(dx < 0 ? .left : .right) }
            return .step(dy < 0 ? .down : .up)
        }

        let along = horizontal ? dx : dy
        let across = horizontal ? dy : dx
        guard abs(along) > Self.threshold, abs(along) > abs(across) else { return .none }
        rebase(touches)
        return .open(reversed: along < 0)
    }

    private mutating func rebase(_ touches: [String: (x: Double, y: Double)]) {
        for (id, position) in touches { baseline[id] = position }
    }
}
