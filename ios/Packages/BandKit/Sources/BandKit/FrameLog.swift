import BandProtocol
import Foundation

/// Bounded in-memory log of raw notifications, for the Debug screen and session export (PLAN.md §7.2).
///
/// Only heart-rate and WHOOP custom notify characteristics are kept. Other characteristics
/// (device information strings, which carry serials) are dropped on append and again on export.
public struct FrameLog: Sendable, Equatable {
    public struct Entry: Sendable, Equatable, Identifiable {
        public let id: Int
        public let date: Date
        /// Short id, e.g. `2a37` or `61080003`; for a decoded frame, the packet-type byte as hex.
        public let characteristic: String
        public let bytes: [UInt8]
        /// The frame header, set only when this entry came from a decoded frame (`.rawFrame`).
        /// Nil for raw notification entries.
        public let packetType: UInt8?
        public let seq: UInt8?
        public let cmd: UInt8?

        public init(
            id: Int,
            date: Date,
            characteristic: String,
            bytes: [UInt8],
            packetType: UInt8? = nil,
            seq: UInt8? = nil,
            cmd: UInt8? = nil
        ) {
            self.id = id
            self.date = date
            self.characteristic = characteristic
            self.bytes = bytes
            self.packetType = packetType
            self.seq = seq
            self.cmd = cmd
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
    /// Decoded frames (`.rawFrame` events, the 0x2B flood included), oldest first. A separate,
    /// much smaller ring than `entries`: the flood would otherwise evict the HR notifications the
    /// Debug export needs, and the viewer caps its rendering anyway.
    public private(set) var frames: [Entry] = []
    private var nextID = 0
    private var frameCapacity: Int

    public init(capacity: Int = 4096, frameCapacity: Int = 200) {
        precondition(capacity > 0, "FrameLog capacity must be positive")
        precondition(frameCapacity > 0, "FrameLog frameCapacity must be positive")
        self.capacity = capacity
        self.frameCapacity = frameCapacity
    }

    public var count: Int { entries.count }
    public var frameCount: Int { frames.count }

    public mutating func append(characteristic: String, bytes: [UInt8], at date: Date) {
        let short = characteristic.lowercased()
        guard Self.recordedCharacteristics.contains(short) else { return }
        entries.append(Entry(id: nextID, date: date, characteristic: short, bytes: bytes))
        nextID += 1
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    /// One decoded frame from the band (`BandEvent.rawFrame`). Keeps only the header fields and
    /// the payload — no hex is built here, so the 0x2B flood costs an array append, nothing more.
    public mutating func append(frame: Frame, at date: Date) {
        frames.append(Entry(
            id: nextID,
            date: date,
            characteristic: String(format: "%02x", frame.type),
            bytes: frame.payload,
            packetType: frame.type,
            seq: frame.seq,
            cmd: frame.cmd
        ))
        nextID += 1
        if frames.count > frameCapacity {
            frames.removeFirst(frames.count - frameCapacity)
        }
    }

    /// The newest `limit` entries, newest first.
    public func latest(_ limit: Int) -> [Entry] {
        Array(entries.suffix(max(limit, 0)).reversed())
    }

    /// The newest `limit` decoded frames, newest first.
    public func latestFrames(_ limit: Int) -> [Entry] {
        Array(frames.suffix(max(limit, 0)).reversed())
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
