import Foundation

/// Request body encoding for batch uploads (PLAN.md 11.3). On Apple platforms the body is gzip, and elsewhere it
/// goes as-is with no Content-Encoding header. The server accepts both.
public enum BodyEncoding {
    /// The wire bytes and the Content-Encoding to send with them (nil for identity).
    public static func encode(_ json: Data) -> (body: Data, contentEncoding: String?) {
        #if canImport(Darwin)
        if let deflated = rawDeflate(json) {
            return (GzipFraming.frame(deflate: deflated, crc32: GzipFraming.crc32(json), inputSize: json.count), "gzip")
        }
        #endif
        return (json, nil)
    }

    #if canImport(Darwin)
    /// `NSData.compressed(using: .zlib)` gives a raw DEFLATE stream (RFC 1951), which is what gzip wraps.
    /// [Unverified] Confirm on macOS CI: a zlib-wrapped result would need its 2-byte header and 4-byte Adler-32
    /// trailer removed first. The server rejects a corrupt gzip body, so this path must be checked before release.
    private static func rawDeflate(_ data: Data) -> Data? {
        guard let compressed = try? (data as NSData).compressed(using: .zlib) else { return nil }
        return compressed as Data
    }
    #endif
}

/// gzip framing (RFC 1952) around a raw DEFLATE stream. Pure Swift, so it is tested on Linux as well.
public enum GzipFraming {
    /// Header with no name, no mtime and OS = Unix.
    static let header: [UInt8] = [0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03]

    /// `header + deflate + CRC-32 + ISIZE`, both trailer fields little-endian.
    public static func frame(deflate: Data, crc32: UInt32, inputSize: Int) -> Data {
        var output = Data(header)
        output.append(deflate)
        output.append(littleEndian(crc32))
        output.append(littleEndian(UInt32(truncatingIfNeeded: inputSize)))
        return output
    }

    /// CRC-32 (IEEE 802.3, reflected polynomial 0xEDB88320), as gzip uses it.
    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    private static func littleEndian(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)])
    }
}
