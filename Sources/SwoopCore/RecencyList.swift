/// Window IDs, most recently used first. macOS only reports stacking order for
/// the current Space, so recency has to be tracked across Spaces here.
public struct RecencyList: Equatable {
    public private(set) var order: [UInt32] = []

    public init() {}

    public mutating func touch(_ id: UInt32) {
        order.removeAll { $0 == id }
        order.insert(id, at: 0)
    }

    /// Drops windows that have gone and adds new ones behind the known ones,
    /// keeping the order they were given in (front to back).
    public mutating func reconcile(with ids: [UInt32]) {
        let live = Set(ids)
        order.removeAll { !live.contains($0) }
        var seen = Set(order)
        for id in ids where seen.insert(id).inserted {
            order.append(id)
        }
    }
}
