import Foundation
import Testing
@testable import BandProtocol

// Version-24 HISTORICAL_DATA records, built from synthetic bytes, plus the golden S8 frames as
// unsupported-version fixtures (see the HistoricalRecord doc comment for the cross-check).
@Suite("Historical records")
struct HistoricalRecordTests {
    // MARK: Golden loading (same navigation as GoldenFrameTests)

    private struct GoldenFrame: Decodable {
        let name: String
        let hex: String
    }

    private enum GoldenError: Error {
        case badHex(String)
    }

    private func loadFrames() throws -> [GoldenFrame] {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // BandProtocolTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // BandProtocol
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // repo root
        let url = repoRoot.appendingPathComponent("shared/golden/frames.json")
        return try JSONDecoder().decode([GoldenFrame].self, from: Data(contentsOf: url))
    }

    private func bytes(fromHex hex: String) throws -> [UInt8] {
        guard hex.count % 2 == 0 else { throw GoldenError.badHex(hex) }
        var result: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { throw GoldenError.badHex(hex) }
            result.append(byte)
            index = next
        }
        return result
    }

    // MARK: Synthetic version-24 payload

    private func littleEndian(_ value: UInt32, into payload: inout [UInt8], at offset: Int) {
        payload[offset] = UInt8(value & 0xFF)
        payload[offset + 1] = UInt8((value >> 8) & 0xFF)
        payload[offset + 2] = UInt8((value >> 16) & 0xFF)
        payload[offset + 3] = UInt8(value >> 24)
    }

    private func littleEndian(_ value: UInt16, into payload: inout [UInt8], at offset: Int) {
        payload[offset] = UInt8(value & 0xFF)
        payload[offset + 1] = UInt8(value >> 8)
    }

    private func littleEndian(_ value: Float, into payload: inout [UInt8], at offset: Int) {
        littleEndian(value.bitPattern, into: &payload, at: offset)
    }

    /// A full version-24 payload with a distinct, plausible value in every documented field.
    /// The undocumented gaps carry a marker byte, proving the parser ignores them. Offsets here are
    /// `Frame.payload` offsets (= NOOP's frame-absolute offsets minus the 7-byte envelope).
    private func v24Payload(
        unix: UInt32 = 1_791_382_500,
        bpm: UInt8 = 55,
        rr: [UInt16] = [995, 1004],
        skinContact: UInt8 = 1
    ) -> [UInt8] {
        var payload = [UInt8](repeating: 0x55, count: 77)
        littleEndian(unix, into: &payload, at: 4)
        payload[14] = bpm
        payload[15] = UInt8(rr.count)
        for (index, value) in rr.enumerated() {
            littleEndian(value, into: &payload, at: 16 + index * 2)
        }
        littleEndian(UInt16(0x3CE0), into: &payload, at: 26) // ppg green
        littleEndian(UInt16(0x4614), into: &payload, at: 28) // ppg red/ir
        littleEndian(Float(0.01), into: &payload, at: 33)
        littleEndian(Float(-0.02), into: &payload, at: 37)
        littleEndian(Float(0.99), into: &payload, at: 41)
        payload[48] = skinContact
        littleEndian(Float(0.5), into: &payload, at: 49)
        littleEndian(Float(-0.25), into: &payload, at: 53)
        littleEndian(Float(0.75), into: &payload, at: 57)
        littleEndian(UInt16(0x1F40), into: &payload, at: 61) // SpO2 red
        littleEndian(UInt16(0x2EE0), into: &payload, at: 63) // SpO2 ir
        littleEndian(UInt16(0x0F3C), into: &payload, at: 65) // skin temp raw
        littleEndian(UInt16(0x0102), into: &payload, at: 67) // ambient drive
        littleEndian(UInt16(0x0204), into: &payload, at: 69) // led drive 1
        littleEndian(UInt16(0x0308), into: &payload, at: 71) // led drive 2
        littleEndian(UInt16(0x0294), into: &payload, at: 73) // resp rate raw
        littleEndian(UInt16(0x00F0), into: &payload, at: 75) // signal quality
        return payload
    }

    private func v24Frame(seq: UInt8 = 24, payload: [UInt8]) -> Frame {
        Frame(type: PacketType.historicalData.rawValue, seq: seq, cmd: 7, payload: payload)
    }

    // MARK: Parsing

    @Test func parsesEveryDocumentedField() throws {
        let record = try HistoricalRecord.parse(v24Frame(payload: v24Payload()))

        #expect(record.version == 24)
        #expect(record.unixSeconds == 1_791_382_500)
        #expect(record.heartRate == 55)
        #expect(record.rrIntervalsMs == [995, 1004])
        #expect(record.ppgGreen == 0x3CE0)
        #expect(record.ppgRedIr == 0x4614)
        #expect(record.gravity == .init(x: Double(Float(0.01)), y: Double(Float(-0.02)), z: Double(Float(0.99))))
        #expect(record.skinContact == true)
        #expect(record.secondaryGravity == .init(x: 0.5, y: -0.25, z: 0.75))
        #expect(record.spo2Red == 0x1F40)
        #expect(record.spo2Ir == 0x2EE0)
        #expect(record.skinTempRaw == 0x0F3C)
        #expect(record.ambientDrive == 0x0102)
        #expect(record.ledDrive1 == 0x0204)
        #expect(record.ledDrive2 == 0x0308)
        #expect(record.respRateRaw == 0x0294)
        #expect(record.signalQuality == 0x00F0)
    }

    @Test func zeroSkinContactMeansOffWrist() throws {
        let record = try HistoricalRecord.parse(v24Frame(payload: v24Payload(skinContact: 0)))
        #expect(record.skinContact == false)
    }

    @Test func rrCountIsClampedToTheFiveFixedSlots() throws {
        // rr_count = 8 would run the interval region into the fixed fields; the parser keeps the
        // five slots at payload offsets 16-25 and drops the excess.
        let record = try HistoricalRecord.parse(v24Frame(payload: v24Payload(rr: [10, 11, 12, 13, 14, 15, 16, 17])))
        #expect(record.rrIntervalsMs == [10, 11, 12, 13, 14])
    }

    @Test func zeroRRCountMeansNoIntervals() throws {
        let record = try HistoricalRecord.parse(v24Frame(payload: v24Payload(rr: [])))
        #expect(record.rrIntervalsMs.isEmpty)
    }

    @Test func trailingBytesBeyondTheTableAreIgnored() throws {
        var payload = v24Payload()
        payload.append(contentsOf: [0xAA, 0xBB, 0xCC])
        let record = try HistoricalRecord.parse(v24Frame(payload: payload))
        #expect(record.signalQuality == 0x00F0)
    }

    // MARK: The real on-wrist WHOOP 4.0 record (NOOP, fw 41.17.6.0, captured 2026-06-08)

    /// A complete, CRC-valid type-47 frame captured off a real WHOOP 4.0 (NOOP
    /// `Whoop4HistoricalV24HardwareTests`). Truth: unix 1,780,928,574 (2026-06-08), HR 109,
    /// R-R [555, 564], |gravity| ≈ 1 g. This pins the payload offsets against real hardware.
    private static let realWhoop4FrameHex =
        "aa6400a12f18054c1c0a023ed0266a5037805418016d022b0234020000000000006b07ff00" +
        "85593c1f65cebed7b3e63eb85a5f3f000080401f65cebed7b3e63eb85a5f3f500264025d03" +
        "640229014009010c020c00000000000f0001c4020000000000008fdeb278"

    @Test func decodesTheRealOnWristWhoop4Frame() throws {
        let frame = try FrameCodec.decode(try bytes(fromHex: Self.realWhoop4FrameHex))
        #expect(frame.packetType == .historicalData)
        #expect(frame.seq == 24)

        let record = try HistoricalRecord.parse(frame)
        #expect(record.unixSeconds == 1_780_928_574)
        #expect(record.heartRate == 109)
        #expect(record.rrIntervalsMs == [555, 564])
        #expect(record.skinContact == true)
        // Physiological cross-check: 60000 / mean(R-R) ≈ heart rate.
        let mean = Double(record.rrIntervalsMs.reduce(0, +)) / Double(record.rrIntervalsMs.count)
        #expect(abs(60000 / mean - 109) < 3)
        // Gravity is a DSP orientation vector: |g| ≈ 1 g on a real record.
        let g = record.gravity
        let magnitude = (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot()
        #expect(abs(magnitude - 1.0) < 0.1)
        // Worn skin temperature lands near NOOP's observed ~826 worn / ~510 no-contact floor.
        #expect((500...1000).contains(record.skinTempRaw))
    }

    // MARK: Rejections

    /// The typed parse error, or nil when parsing unexpectedly succeeded.
    private func parseError(of frame: Frame) -> HistoricalRecord.ParseError? {
        do {
            _ = try HistoricalRecord.parse(frame)
            return nil
        } catch {
            return error
        }
    }

    @Test func rejectsFramesOfOtherPacketTypes() {
        let frame = Frame(type: PacketType.realtimeData.rawValue, seq: 24, cmd: 2, payload: v24Payload())
        #expect(parseError(of: frame) == .notHistoricalData(PacketType.realtimeData.rawValue))
    }

    @Test func rejectsTooShortPayloads() {
        var payload = v24Payload()
        payload.removeLast()
        #expect(parseError(of: v24Frame(payload: payload)) == .payloadTooShort(length: 76, required: 77))
    }

    @Test func rejectsUnknownVersions() {
        #expect(parseError(of: v24Frame(seq: 25, payload: v24Payload())) == .unsupportedVersion(25))
    }

    /// The eight golden type-47 frames are S8 version-12 records with a different layout, so the
    /// version-24 parser must reject them on the version byte.
    @Test func rejectsTheGoldenVersion12Records() throws {
        let golden = try loadFrames().filter { $0.name.hasPrefix("historical_seq0c_") }
        #expect(golden.count == 8)
        for frame in golden {
            let decoded = try FrameCodec.decode(try bytes(fromHex: frame.hex))
            #expect(decoded.packetType == .historicalData)
            #expect(decoded.seq == 12)
            #expect(parseError(of: decoded) == .unsupportedVersion(12))
        }
    }

    // MARK: Metadata token

    /// The token is `inner[13:21]`, which is `payload[10..<18]` (the inner bytes start at frame
    /// byte 4). All four golden metadata frames carry the same constant 8 bytes there.
    @Test func tokenComesFromTheGoldenMetadataFrames() throws {
        let golden = try loadFrames().filter { $0.name.hasPrefix("metadata_seq") }
        #expect(golden.count == 4)
        for frame in golden {
            let decoded = try FrameCodec.decode(try bytes(fromHex: frame.hex))
            #expect(decoded.packetType == .metadata)
            let token = try #require(HistoricalMetadata.token(fromPayload: decoded.payload))
            #expect(token == [0x2E, 0x47, 0x01, 0x00, 0x04, 0x00, 0x00, 0x00])
        }
    }

    @Test func tooShortMetadataHasNoToken() {
        #expect(HistoricalMetadata.token(fromPayload: []) == nil)
        #expect(HistoricalMetadata.token(fromPayload: [UInt8](repeating: 0, count: 17)) == nil)
    }

    // MARK: Offload commands

    @Test func sendHistoricalDataCarriesTheStandardCommandByte() throws {
        let frame = try FrameCodec.decode(BandCommand.sendHistoricalData().frame(seq: 9))
        #expect(frame.packetType == .command)
        #expect(frame.cmd == SafeCommand.sendHistoricalData.rawValue)
        #expect(frame.payload == [0x00])
    }

    /// NOOP hardware-verified ack shape: the payload leads with 0x01, then the 8-byte end-data.
    @Test func historicalDataResultLeadsWithTheAckByte() throws {
        let token: [UInt8] = [0x2E, 0x47, 0x01, 0x00, 0x04, 0x00, 0x00, 0x00]
        let frame = try FrameCodec.decode(BandCommand.historicalDataResult(token: token).frame(seq: 10))
        #expect(frame.packetType == .command)
        #expect(frame.cmd == SafeCommand.historicalDataResult.rawValue)
        #expect(frame.payload == [0x01] + token)
    }

    /// WHOOP 4 fw 41.17.x latches only the 9-byte SET_CLOCK: `[u32 LE][5 zero]` (NOOP, verified).
    @Test func setClockLegacyIsNineBytes() throws {
        let frame = try FrameCodec.decode(BandCommand.setClockLegacy(unix: 0x11223344).frame(seq: 11))
        #expect(frame.packetType == .command)
        #expect(frame.cmd == SafeCommand.setClock.rawValue)
        #expect(frame.payload == [0x44, 0x33, 0x22, 0x11, 0, 0, 0, 0, 0])
        // The two forms carry the same seconds.
        let eight = try FrameCodec.decode(BandCommand.setClock(unix: 0x11223344).frame(seq: 12))
        #expect(Array(eight.payload[0..<4]) == Array(frame.payload[0..<4]))
        #expect(eight.payload.count == 8)
    }
}
