/// Inner packet type (byte 0 of the frame body), PLAN.md 5.3.4.
public enum PacketType: UInt8, Sendable, Equatable {
    case command = 0x23
    case commandResponse = 0x24
    case realtimeData = 0x28
    case realtimeRawData = 0x2B
    case historicalData = 0x2F
    case event = 0x30
    case metadata = 0x31
    case consoleLogs = 0x32
}

/// A decoded frame. `cmd` is the command, event or record byte depending on `type`.
public struct Frame: Sendable, Equatable {
    public let type: UInt8
    public let seq: UInt8
    public let cmd: UInt8
    public let payload: [UInt8]

    public init(type: UInt8, seq: UInt8, cmd: UInt8, payload: [UInt8]) {
        self.type = type
        self.seq = seq
        self.cmd = cmd
        self.payload = payload
    }

    public var packetType: PacketType? { PacketType(rawValue: type) }
}

public enum FrameError: Error, Equatable, Sendable {
    case tooShort(count: Int)
    case badSyncByte(UInt8)
    case headerCRCMismatch
    case invalidLength(Int)
    case lengthMismatch(expected: Int, actual: Int)
    case payloadCRCMismatch
}

/// WHOOP 4.0 envelope: [0xAA][len u16 LE][crc8 of the len bytes][type][seq][cmd][payload][crc32 LE].
/// `len` counts the inner bytes plus the 4-byte CRC-32, so the frame is `len + 4` bytes long.
public enum FrameCodec {
    public static let syncByte: UInt8 = 0xAA

    /// The only public encoder for COMMAND (0x23) frames. Opcodes outside `SafeCommand` cannot be sent.
    public static func encodeCommand(_ command: SafeCommand, seq: UInt8, payload: [UInt8] = []) -> [UInt8] {
        encode(type: PacketType.command.rawValue, seq: seq, cmd: command.rawValue, payload: payload)
    }

    public static func decode(_ bytes: [UInt8]) throws(FrameError) -> Frame {
        guard bytes.count >= 4 else { throw .tooShort(count: bytes.count) }
        guard bytes[0] == syncByte else { throw .badSyncByte(bytes[0]) }
        guard CRC.crc8(bytes[1...2]) == bytes[3] else { throw .headerCRCMismatch }

        let length = Int(bytes[1]) | (Int(bytes[2]) << 8)
        guard length >= 7 else { throw .invalidLength(length) }
        let expected = 4 + length
        guard bytes.count == expected else {
            throw .lengthMismatch(expected: expected, actual: bytes.count)
        }

        let body = Array(bytes[4..<length])
        let stored = UInt32(bytes[length])
            | (UInt32(bytes[length + 1]) << 8)
            | (UInt32(bytes[length + 2]) << 16)
            | (UInt32(bytes[length + 3]) << 24)
        guard CRC.crc32(body) == stored else { throw .payloadCRCMismatch }

        return Frame(type: body[0], seq: body[1], cmd: body[2], payload: Array(body.dropFirst(3)))
    }

    /// Internal so that only `encodeCommand` can produce COMMAND frames outside tests.
    static func encode(type: UInt8, seq: UInt8, cmd: UInt8, payload: [UInt8]) -> [UInt8] {
        let length = payload.count + 7
        precondition(length <= Int(UInt16.max), "payload too large for the frame envelope")
        let lengthBytes: [UInt8] = [UInt8(length & 0xFF), UInt8(length >> 8)]
        let body: [UInt8] = [type, seq, cmd] + payload
        let crc = CRC.crc32(body)
        let crcBytes: [UInt8] = [
            UInt8(crc & 0xFF),
            UInt8((crc >> 8) & 0xFF),
            UInt8((crc >> 16) & 0xFF),
            UInt8(crc >> 24),
        ]
        return [syncByte] + lengthBytes + [CRC.crc8(lengthBytes)] + body + crcBytes
    }
}
