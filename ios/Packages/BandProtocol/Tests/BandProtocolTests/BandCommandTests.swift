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

    // MARK: Envelope vectors (no captured band frame exists for these)

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
        ]
        for command in commands {
            #expect(SafeCommand(rawValue: command.command.rawValue) == command.command)
            #expect(!SafeCommand.deniedOpcodes.contains(command.command.rawValue))
        }
        #expect(Set(commands.map(\.command.rawValue)) == [3, 11, 14, 26, 34, 63, 66, 67, 79, 80, 122])
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
