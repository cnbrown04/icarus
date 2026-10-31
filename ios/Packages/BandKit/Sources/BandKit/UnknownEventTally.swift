/// Counts EVENT (0x30) ids the parser does not name (`BandEventKind.unknown`), so new firmware events
/// can be named from real captures (whoop-parity §3.11). Session-scoped: the owner decides the lifetime.
public struct UnknownEventTally: Sendable, Equatable {
    public private(set) var counts: [UInt8: Int] = [:]

    public init() {}

    public mutating func record(_ id: UInt8) {
        counts[id, default: 0] += 1
    }

    /// (id, count) pairs, most frequent first, ties by ascending id.
    public var sorted: [(id: UInt8, count: Int)] {
        counts
            .map { (id: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.id < $1.id }
    }
}
