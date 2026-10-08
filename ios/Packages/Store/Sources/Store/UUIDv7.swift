import Foundation

/// Time-ordered UUIDs for client-created rows (PLAN.md 10.1). The first 48 bits are the Unix ms.
public enum UUIDv7 {
    public static func make(unixMs: Int64) -> UUID {
        var generator = SystemRandomNumberGenerator()
        return make(unixMs: unixMs, using: &generator)
    }

    public static func make<G: RandomNumberGenerator>(unixMs: Int64, using generator: inout G) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        let ms = UInt64(max(unixMs, 0)) & 0xFFFF_FFFF_FFFF
        for index in 0..<6 {
            bytes[index] = UInt8((ms >> UInt64(40 - 8 * index)) & 0xFF)
        }
        for index in 6..<16 {
            bytes[index] = UInt8.random(in: 0...255, using: &generator)
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x70
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { byte -> String in
            let digits = String(byte, radix: 16)
            return digits.count == 1 ? "0" + digits : digits
        }.joined()
        let text = [
            hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4),
            hex.dropFirst(16).prefix(4), hex.dropFirst(20),
        ].joined(separator: "-")
        return UUID(uuidString: text)!
    }
}
