/// Which tile is highlighted while the switcher is open. Starts one step from the
/// window you're on, so a quick tap-and-release swaps between the last two, the same
/// as Alt+Tab on Windows. If that window isn't listed, the first step is the first tile.
public struct Selection: Equatable {
    public private(set) var count: Int
    public private(set) var index: Int

    /// `current` is where the focused window is in the list, if it's there at all.
    public init(count: Int, reversed: Bool = false, current: Int? = nil) {
        self.count = count
        guard count > 0 else {
            index = 0
            return
        }
        if let current {
            index = (current + (reversed ? count - 1 : 1)) % count
        } else {
            index = reversed ? count - 1 : 0
        }
    }

    public mutating func next() {
        guard count > 0 else { return }
        index = (index + 1) % count
    }

    public mutating func previous() {
        guard count > 0 else { return }
        index = (index - 1 + count) % count
    }

    /// Moves a row up or down the grid, staying put if there's no tile there.
    public mutating func moveRows(_ rows: Int, columns: Int) {
        guard columns > 0 else { return }
        let target = index + rows * columns
        if target >= 0 && target < count {
            index = target
        }
    }

    /// Replaces the list while the switcher is open, keeping the highlight on
    /// the same tile when it still exists.
    public mutating func update(count: Int, index: Int?) {
        self.count = count
        if let index {
            self.index = index
        } else {
            self.index = count == 0 ? 0 : min(self.index, count - 1)
        }
    }
}
