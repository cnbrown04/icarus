/// CRC routines for the WHOOP 4.0 frame envelope (PLAN.md 5.3.3).
enum CRC {
    /// CRC-8, polynomial 0x07, init 0, no reflection, no final XOR.
    static func crc8<S: Sequence>(_ bytes: S) -> UInt8 where S.Element == UInt8 {
        var crc: UInt8 = 0
        for byte in bytes {
            crc ^= byte
            for _ in 0..<8 {
                crc = crc & 0x80 != 0 ? (crc << 1) ^ 0x07 : crc << 1
            }
        }
        return crc
    }

    /// Standard zlib CRC-32 (reflected, polynomial 0xEDB88320, init and final XOR 0xFFFFFFFF).
    static func crc32<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = crc32Table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let crc32Table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }
}
