import Foundation
import Testing
@testable import BandProtocol

// Golden frames from shared/golden/frames.json (S8). The reproduction tests below rebuild each frame
// from its typed builder and compare bytes. Envelope vectors without a golden frame were computed
// with the PLAN.md 5.3.3 envelope; they fix the encoding but are not captured from a band.
@Suite("Typed band commands")
struct BandCommandTests {
    private struct GoldenFrame: Decodable {
        let name: String
        let hex: String
    }

    private func loadGolden() throws -> [GoldenFrame] {
        // Test file: <repo>/ios/Packages/BandProtocol/Tests/BandProtocolTests/BandCommandTests.swift
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

    private func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start ..< hex.index(start, offsetBy: 2)], radix: 16)!
        }
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Golden reproduction

    @Test func setAlarmTimeReproducesEverySetAlarmGoldenFrame() throws {
        let frames = try loadGolden().filter { $0.name.hasPrefix("set_alarm_") }
        #expect(frames.count == 7)
        for golden in frames {
            let raw = bytes(golden.hex)
            let frame = try FrameCodec.decode(raw)
            let p = frame.payload
            #expect(p.count == 9)
            #expect(p[0] == 0x01 && Array(p[5...]) == [0, 0, 0, 0], "\(golden.name)")
            let unix = UInt32(p[1]) | (UInt32(p[2]) << 8) | (UInt32(p[3]) << 16) | (UInt32(p[4]) << 24)
            let rebuilt = BandCommand.setAlarmTime(unix: unix).frame(seq: frame.seq)
            #expect(rebuilt == raw, "\(golden.name)")
        }
    }

    @Test func hrBroadcastReproducesGoldenFrames() throws {
        let frames = try loadGolden().filter { $0.name.hasPrefix("hr_broadcast_") }
        #expect(frames.count == 3)
        for golden in frames {
            let raw = bytes(golden.hex)
            let frame = try FrameCodec.decode(raw)
            let on = golden.name.contains("_on_")
            #expect(BandCommand.hrBroadcast(on: on).frame(seq: frame.seq) == raw, "\(golden.name)")
        }
    }

    @Test func realtimeHeartRateToggleReproducesHealthMonitorGoldenFrames() throws {
        let frames = try loadGolden().filter { $0.name.hasPrefix("health_monitor_") }
        #expect(frames.count == 2)
        for golden in frames {
            let raw = bytes(golden.hex)
            let frame = try FrameCodec.decode(raw)
            let on = golden.name.hasSuffix("_on")
            #expect(BandCommand.toggleRealtimeHR(on: on).frame(seq: frame.seq) == raw, "\(golden.name)")
        }
    }

    /// SEND_R10_R11_REALTIME (cmd 63): `[0x01]` turns the REALTIME_RAW_DATA (type 0x2B) raw
    /// accel/PPG flood on, `[0x00]` off (NOOP [S12], whoop-parity §3.4). No golden frame exists and
    /// no Icarus capture shows a cmd-63 frame, so the envelope vector below fixes the encoding but
    /// the payload forms are [Unverified] beyond the NOOP source.
    @Test func realtimeRawToggleEncodesItsPayloadForms() {
        let off = BandCommand.toggleRealtimeRaw(on: false)
        let on = BandCommand.toggleRealtimeRaw(on: true)
        #expect(off.command == .sendR10R11Realtime)
        #expect(off.command.rawValue == 63)
        #expect(off.payload == [0x00])
        #expect(on.payload == [0x01])
        #expect(hex(off.frame(seq: 0x14)) == "aa0800a823143f005cfe32d0")
        #expect(hex(on.frame(seq: 0x15)) == "aa0800a823153f01fda4f7a6")
    }

    /// LINK_VALID (cmd 1) and GET_EXTENDED_BATTERY_INFO (cmd 98) carry the standard `[0x00]` byte
    /// and their envelopes are byte-exact (same CRC-8 / CRC-32 convention as the stop-haptics and
    /// battery vectors). No capture pins either frame.
    @Test func linkValidAndExtendedBatteryEncodeWithAPayloadByte() {
        let link = BandCommand.linkValid()
        #expect(link.command == .linkValid)
        #expect(link.command.rawValue == 1)
        #expect(link.payload == [0x00])
        #expect(hex(link.frame(seq: 0x1A)) == "aa0800a8231a01002bc8699b")

        let extended = BandCommand.getExtendedBatteryInfo()
        #expect(extended.command == .getExtendedBatteryInfo)
        #expect(extended.command.rawValue == 98)
        #expect(extended.payload == [0x00])
        #expect(hex(extended.frame(seq: 0x1B)) == "aa0800a8231b6200789a7bd4")
    }

    // MARK: Envelope vectors (no captured band frame exists for these)

    /// SET_READ_POINTER (cmd 33, 0x21): the u32 offset, little-endian (OpenStrap §2/§4.3,
    /// `research_playground.py:cmd_set_read_pointer` = `struct.pack("<I", off)`). The envelope
    /// vectors below follow this repo's own envelope convention (PLAN.md 5.3.3: an unpadded inner,
    /// unlike OpenStrap's /4-padded upstream form); no capture pins a cmd-33 frame yet, and the
    /// offset's unit (pages vs bytes) is [Unverified].
    @Test func setReadPointerEncodesTheOffsetLittleEndian() {
        let command = BandCommand.setReadPointer(offset: 67_491)
        #expect(command.command.rawValue == 33)
        #expect(command.command == .setReadPointer)
        #expect(command.payload == [0xA3, 0x07, 0x01, 0x00])
        #expect(hex(command.frame(seq: 0x16)) == "aa0c00fc231621a3070100007372b771")
        let zero = BandCommand.setReadPointer(offset: 0)
        #expect(zero.payload == [0, 0, 0, 0])
        #expect(hex(zero.frame(seq: 0x17)) == "aa0c00fc23172100000000000fce527c")
        let rewind = BandCommand.setReadPointer(offset: 5_000)
        #expect(rewind.payload == [0x88, 0x13, 0x00, 0x00])
        #expect(hex(rewind.frame(seq: 0x18)) == "aa0c00fc2318218813000000c4bd2049")
    }

    /// Commands are zero-padded to a 4-byte inner (OpenStrap `pad4`): the bare-u32 SET_READ_POINTER was
    /// discarded by the strap until it carried the trailing zero.
    @Test func setReadPointerIsPaddedToAFourByteInner() throws {
        let frame = try FrameCodec.decode(BandCommand.setReadPointer(offset: 125_324).frame(seq: 0x1C))
        #expect(frame.cmd == 33)
        #expect(frame.payload == [0x8C, 0xE9, 0x01, 0x00, 0x00])
        #expect((3 + frame.payload.count) % 4 == 0)
    }

    @Test func runHapticsPatternPayloadIsPatternLoopsAndZeros() {
        let command = BandCommand.runHapticsPattern(patternId: 2, loops: 3)
        #expect(command.command == .runHapticsPattern)
        #expect(command.payload == [2, 3, 0, 0, 0])
        #expect(hex(command.frame(seq: 0x10)) == "aa0c00fc23104f020300000025627ee3")
    }

    /// STOP_HAPTICS (cmd 122) carries the standard `[0x00]` command byte (NOOP, verified on 4.0).
    @Test func stopHapticsIsCommand122WithTheStandardCommandByte() {
        let command = BandCommand.stopHaptics()
        #expect(command.command.rawValue == 122)
        #expect(command.payload == [0x00])
        #expect(hex(command.frame(seq: 0x11)) == "aa0800a823117a00f787f75b")
    }

    @Test func setAlarmTimeEncodesUnixSecondsLittleEndian() {
        let command = BandCommand.setAlarmTime(unix: 1_717_909_200)
        #expect(command.payload == [0x01, 0xD0, 0x36, 0x65, 0x66, 0, 0, 0, 0])
        #expect(hex(command.frame(seq: 0x12)) == "aa10005723124201d036656600000000c38b31ec")
    }

    /// Every GET-style read carries at least one payload byte: a truly empty payload is ACKed by
    /// the strap but silently discarded by its command processor (NOOP). GET_ALARM_TIME carries
    /// `[0x01]`; the rest carry the standard `[0x00]` command byte.
    @Test func readsEncodeWithTheirOpcodesAndAPayloadByte() {
        #expect(hex(BandCommand.getBatteryLevel().frame(seq: 0x12)) == "aa0800a823121a0009524c3c")
        #expect(hex(BandCommand.getClock().frame(seq: 0x13)) == "aa0800a823130b002e1b576e")
        #expect(BandCommand.getAlarmTime().command.rawValue == 67)
        #expect(BandCommand.getDataRange().command.rawValue == 34)
        #expect(BandCommand.getAllHapticsPatterns().command.rawValue == 80)
        #expect(BandCommand.getAlarmTime().payload == [0x01])
        for command in [BandCommand.getDataRange(), .getAllHapticsPatterns(), .getClock(), .getBatteryLevel()] {
            #expect(command.payload == [0x00])
        }
    }

    @Test func everyBuilderUsesAWhitelistedOpcode() {
        let commands: [BandCommand] = [
            .runHapticsPattern(patternId: 2, loops: 1), .stopHaptics(), .setAlarmTime(unix: 1), .getAlarmTime(),
            .getClock(), .getBatteryLevel(), .getDataRange(), .toggleRealtimeHR(on: true),
            .toggleRealtimeRaw(on: false), .hrBroadcast(on: false), .getAllHapticsPatterns(),
            .setReadPointer(offset: 0),
        ]
        for command in commands {
            #expect(SafeCommand(rawValue: command.command.rawValue) == command.command)
            #expect(!SafeCommand.deniedOpcodes.contains(command.command.rawValue))
        }
        #expect(Set(commands.map(\.command.rawValue)) == [3, 11, 14, 26, 33, 34, 63, 66, 67, 79, 80, 122])
    }

    // MARK: Battery reply

    @Test func batteryReplyIsU16TenthsOfAPercent() {
        // Replies lead with a response counter + status byte; the u16 sits at offset 2
        // (verified live: `03 01 D8 03 …` → 984 → 98.4 %).
        #expect(BatteryLevel.percent(payload: [0x00, 0x01, 0x69, 0x03]) == 87.3)
        #expect(BatteryLevel.percent(payload: [0x01, 0x01, 0xE8, 0x03]) == 100)
        #expect(BatteryLevel.percent(payload: [0x69, 0x03]) == nil)
        #expect(BatteryLevel.percent(payload: [0x69]) == nil)
        #expect(BatteryLevel.percent(payload: []) == nil)
    }
}
