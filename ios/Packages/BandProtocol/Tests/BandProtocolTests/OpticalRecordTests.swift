import Testing
@testable import BandProtocol

@Suite("Optical record (R21)")
struct OpticalRecordTests {
    @Test func decodesSixChannelsAtOpenStrapsOffsets() throws {
        var payload = [UInt8](repeating: 0, count: 1_241)
        payload[4] = 0x10; payload[5] = 0x20; payload[6] = 0x30; payload[7] = 0x6A
        payload[11] = 0x34; payload[12] = 0x12
        payload[13] = 100
        for (channel, start) in OpticalRecord.channelOffsets.enumerated() {
            for sample in 0..<100 {
                let value = UInt16(channel * 1_000 + sample)
                payload[start + sample * 2] = UInt8(value & 0xFF)
                payload[start + sample * 2 + 1] = UInt8(value >> 8)
            }
        }
        let frame = Frame(type: PacketType.realtimeRawData.rawValue, seq: 21, cmd: 0, payload: payload)
        let record = try #require(OpticalRecord.parse(frame))
        #expect(record.unixSeconds == 0x6A30_2010)
        #expect(record.ledDrive == 0x1234)
        #expect(record.sampleCount == 100)
        #expect(record.channels.count == 6)
        #expect(record.channels.allSatisfy { $0.count == 100 })
        #expect(record.channels[2][5] == 2_005)
        #expect(record.channels[5][99] == 5_099)
    }

    @Test func otherFramesAndShortPayloadsAreNotOpticalRecords() {
        let r10 = Frame(type: PacketType.realtimeRawData.rawValue, seq: 10, cmd: 0, payload: [UInt8](repeating: 0, count: 1_300))
        #expect(OpticalRecord.parse(r10) == nil)
        let short = Frame(type: PacketType.realtimeRawData.rawValue, seq: 21, cmd: 0, payload: [UInt8](repeating: 0, count: 600))
        #expect(OpticalRecord.parse(short) == nil)
    }

    @Test func enableOpticalDataCarriesTheRevisionByte() {
        #expect(BandCommand.enableOpticalData(on: true).payload == [0x01, 0x01])
        #expect(BandCommand.enableOpticalData(on: false).payload == [0x01, 0x00])
        #expect(!SafeCommand.deniedOpcodes.contains(107))
        #expect(SafeCommand.deniedOpcodes.contains(108))
        #expect(SafeCommand.deniedOpcodes.contains(154))
    }
}
