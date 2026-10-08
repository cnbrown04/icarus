import Foundation

/// Bounded in-memory log of raw notifications, for the Debug screen and session export (PLAN.md §7.2).
///
/// Only heart-rate and WHOOP custom notify characteristics are kept. Other characteristics
/// (device information strings, which carry serials) are dropped on append and again on export.
public struct FrameLog: Sendable, Equatable {
    public struct Entry: Sendable, Equatable, Identifiable {
        public let id: Int
        public let date: Date
        /// Short id, e.g. `2a37` or `61080003`.
        public let characteristic: String
        public let bytes: [UInt8]

        public init(id: Int, date: Date, characteristic: String, bytes: [UInt8]) {
            self.id = id
            self.date = date
            self.characteristic = characteristic
            self.bytes = bytes
        }

        public var hex: String {
            let digits = Array("0123456789abcdef")
            var text = ""
            text.reserveCapacity(bytes.count * 2)
            for byte in bytes {
                text.append(digits[Int(byte >> 4)])
                text.append(digits[Int(byte & 0x0F)])
            }
            return text
        }
    }

    /// 2A37, plus the WHOOP notify characteristics 61080003, 04, 05 and 07 (PLAN.md §5.3.2).
    public static let recordedCharacteristics: Set<String> = ["2a37", "61080003", "61080004", "61080005", "61080007"]
    /// The session export covers the last ten minutes.
    public static let exportWindow: TimeInterval = 600

    public let capacity: Int
    /// Oldest first.
    public private(set) var entries: [Entry] = []
    private var nextID = 0

    public init(capacity: Int = 4096) {
        precondition(capacity > 0, "FrameLog capacity must be positive")
        self.capacity = capacity
    }

    public var count: Int { entries.count }

    public mutating func append(characteristic: String, bytes: [UInt8], at date: Date) {
        let short = characteristic.lowercased()
        guard Self.recordedCharacteristics.contains(short) else { return }
        entries.append(Entry(id: nextID, date: date, characteristic: short, bytes: bytes))
        nextID += 1
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    /// The newest `limit` entries, newest first.
    public func latest(_ limit: Int) -> [Entry] {
        Array(entries.suffix(max(limit, 0)).reversed())
    }

    /// One JSON object per line, in the fixture format: `{"t":..., "char":"2a37", "hex":"..."}`.
    /// `t` is Unix seconds. Lines carry no device identifiers.
    public func ndjson(since start: Date) -> String {
        var output = ""
        for entry in entries where entry.date >= start && Self.recordedCharacteristics.contains(entry.characteristic) {
            output += "{\"t\":\(entry.date.timeIntervalSince1970),\"char\":\"\(entry.characteristic)\",\"hex\":\"\(entry.hex)\"}\n"
        }
        return output
    }
}
