import Foundation

/// The strap's console (type 50) lines, kept in a bounded ring for the Debug screen (whoop-parity §3.5).
/// Newest last. Appending past `capacity` drops the oldest line, so a chatty firmware cannot grow it.
public struct BandConsoleLog: Sendable, Equatable {
    /// The most lines kept. Matches the Debug screen's "last lines" window.
    public static let capacity = 200

    public struct Line: Sendable, Equatable, Identifiable {
        public let id: Int
        public let at: Date
        public let text: String
    }

    public private(set) var lines: [Line] = []
    private var nextID = 0

    public init() {}

    public mutating func append(_ text: String, at: Date) {
        lines.append(Line(id: nextID, at: at, text: text))
        nextID += 1
        if lines.count > Self.capacity {
            lines.removeFirst(lines.count - Self.capacity)
        }
    }
}
