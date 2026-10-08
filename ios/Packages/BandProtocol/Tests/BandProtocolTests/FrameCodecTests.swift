import Testing
@testable import BandProtocol

@Suite("FrameCodec envelope")
struct FrameCodecTests {
    @Test func encodeLayoutMatchesEnvelope() {
        // Inner = [0x23][seq 0x07][cmd 0x0e][payload 0x00] = 4 bytes.
        // len = 4 + 4 (CRC-32) = 8 -> bytes 0x08 0x00, crc8 of those = 0xA8.
        let bytes = FrameCodec.encodeCommand(.toggleHRBroadcast, seq: 0x07, payload: [0x00])
        #expect(bytes.count == 12)
        #expect(bytes[0] == 0xAA)
        #expect(bytes[1] == 0x08 && bytes[2] == 0x00)
        #expect(bytes[3] == 0xA8)
        #expect(Array(bytes[4..<8]) == [0x23, 0x07, 0x0E, 0x00])
    }

    @Test func decodeReturnsFields() throws {
        let frame = try FrameCodec.decode(FrameCodec.encodeCommand(.setAlarmTime, seq: 0x6D, payload: [0x01, 0x02, 0x03]))
        #expect(frame == Frame(type: 0x23, seq: 0x6D, cmd: 66, payload: [0x01, 0x02, 0x03]))
        #expect(frame.packetType == .command)
    }

    @Test func encodeDecodeRoundTripWithSyncByteInPayload() throws {
        let payload: [UInt8] = [0xAA, 0xAA, 0x00, 0xAA]
        let bytes = FrameCodec.encodeCommand(.runHapticsPattern, seq: 0x01, payload: payload)
        let frame = try FrameCodec.decode(bytes)
        #expect(frame.payload == payload)
        #expect(FrameCodec.encodeCommand(.runHapticsPattern, seq: 0x01, payload: payload) == bytes)
    }

    @Test func rejectsShortInput() {
        #expect(throws: FrameError.tooShort(count: 3)) {
            try FrameCodec.decode([0xAA, 0x08, 0x00])
        }
    }

    @Test func rejectsBadSyncByte() {
        var bytes = FrameCodec.encodeCommand(.getBatteryLevel, seq: 1)
        bytes[0] = 0x55
        #expect(throws: FrameError.badSyncByte(0x55)) {
            try FrameCodec.decode(bytes)
        }
    }

    @Test func rejectsHeaderCRCMismatch() {
        var bytes = FrameCodec.encodeCommand(.getBatteryLevel, seq: 1)
        bytes[3] ^= 0xFF
        #expect(throws: FrameError.headerCRCMismatch) {
            try FrameCodec.decode(bytes)
        }
    }

    @Test func rejectsLengthBelowMinimum() {
        // len 6 cannot hold type, seq, cmd and a CRC-32. The header CRC is computed so only length fails.
        let lengthBytes: [UInt8] = [0x06, 0x00]
        let bytes: [UInt8] = [0xAA] + lengthBytes + [CRC.crc8(lengthBytes)] + [UInt8](repeating: 0, count: 10)
        #expect(throws: FrameError.invalidLength(6)) {
            try FrameCodec.decode(bytes)
        }
    }

    @Test func rejectsLengthMismatch() {
        let bytes = FrameCodec.encodeCommand(.getBatteryLevel, seq: 1)
        #expect(throws: FrameError.lengthMismatch(expected: bytes.count, actual: bytes.count - 1)) {
            try FrameCodec.decode(Array(bytes.dropLast()))
        }
    }

    @Test func rejectsPayloadCRCMismatch() {
        var bytes = FrameCodec.encodeCommand(.setAlarmTime, seq: 0x6D, payload: [0x01, 0x02])
        bytes[5] ^= 0x01 // flip a bit in the seq byte, which the CRC-32 covers
        #expect(throws: FrameError.payloadCRCMismatch) {
            try FrameCodec.decode(bytes)
        }
    }
}
