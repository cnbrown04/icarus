import BandProtocol
import Foundation

/// Parses recorded sessions: one JSON object per line, `{"t": <unix seconds>, "char": "2a37", "hex": "..."}`.
public enum NDJSONFixture {
    public struct Frame: Sendable, Equatable {
        /// Unix seconds, as recorded.
        public let timestamp: Double
        public let measurement: HeartRateMeasurement
    }

    public struct ParseResult: Sendable, Equatable {
        public let frames: [Frame]
        /// Lines that were not valid JSON, were not the 0x2A37 characteristic, had bad hex,
        /// or failed the HR parser. Blank lines are not counted.
        public let skippedLineCount: Int
    }

    static let heartRateCharacteristic = "2a37"

    public static func parse(_ text: String) -> ParseResult {
        var frames: [Frame] = []
        var skipped = 0
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let frame = decodeLine(line) {
                frames.append(frame)
            } else {
                skipped += 1
            }
        }
        return ParseResult(frames: frames, skippedLineCount: skipped)
    }

    private struct Line: Decodable {
        let t: Double
        let char: String
        let hex: String
    }

    private static func decodeLine(_ line: String) -> Frame? {
        guard
            let data = line.data(using: .utf8),
            let entry = try? JSONDecoder().decode(Line.self, from: data),
            entry.char.lowercased() == heartRateCharacteristic,
            let bytes = bytes(fromHex: entry.hex),
            let measurement = try? HeartRateMeasurementParser.parse(bytes)
        else {
            return nil
        }
        return Frame(timestamp: entry.t, measurement: measurement)
    }

    static func bytes(fromHex hex: String) -> [UInt8]? {
        let digits = Array(hex.utf8)
        guard digits.count.isMultiple(of: 2) else { return nil }
        var result: [UInt8] = []
        result.reserveCapacity(digits.count / 2)
        var index = 0
        while index < digits.count {
            guard let high = nibble(digits[index]), let low = nibble(digits[index + 1]) else { return nil }
            result.append((high << 4) | low)
            index += 2
        }
        return result
    }

    private static func nibble(_ character: UInt8) -> UInt8? {
        switch character {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return character - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"):
            return character - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"):
            return character - UInt8(ascii: "A") + 10
        default:
            return nil
        }
    }
}
