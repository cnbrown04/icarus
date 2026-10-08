import Foundation
import Testing
@testable import BandProtocol

// Frames published by bWanShiTong (README, S8). Each one passed both checksums before it was added
// to shared/golden/frames.json (see shared/golden/README.md).
@Suite("Golden frames (S8)")
struct GoldenFrameTests {
    private struct GoldenFrame: Decodable {
        let name: String
        let hex: String
        let source: String
    }

    private enum GoldenError: Error {
        case badHex(String)
    }

    private func loadFrames() throws -> [GoldenFrame] {
        // Test file: <repo>/ios/Packages/BandProtocol/Tests/BandProtocolTests/GoldenFrameTests.swift
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

    @Test func fileContainsEightyFramesFromTheReadme() throws {
        let frames = try loadFrames()
        #expect(frames.count == 80)
        #expect(frames.allSatisfy { $0.source == "S8 bWanShiTong README" })
    }

    @Test func everyFrameDecodesAndReEncodesByteForByte() throws {
        for golden in try loadFrames() {
            let raw = try bytes(fromHex: golden.hex)
            let frame = try FrameCodec.decode(raw)

            if frame.packetType == .command {
                // Only whitelisted commands can be re-encoded. Others are decode-only.
                guard let command = SafeCommand(rawValue: frame.cmd) else { continue }
                let encoded = FrameCodec.encodeCommand(command, seq: frame.seq, payload: frame.payload)
                #expect(encoded == raw, "\(golden.name)")
            } else {
                let encoded = FrameCodec.encode(type: frame.type, seq: frame.seq, cmd: frame.cmd, payload: frame.payload)
                #expect(encoded == raw, "\(golden.name)")
            }
        }
    }

    @Test func rebootFramesDecodeButOpcode29IsNotEncodable() throws {
        let reboots = try loadFrames().filter { $0.name.hasPrefix("reboot_device") }
        #expect(reboots.count == 4)
        for golden in reboots {
            let frame = try FrameCodec.decode(try bytes(fromHex: golden.hex))
            #expect(frame.packetType == .command)
            #expect(frame.cmd == 29)
            #expect(SafeCommand(rawValue: frame.cmd) == nil)
            #expect(SafeCommand.deniedOpcodes.contains(frame.cmd))
        }
    }

    @Test func heartRateBroadcastFramesRoundTrip() throws {
        let frames = try loadFrames().filter { $0.name.hasPrefix("hr_broadcast_") }
        #expect(frames.count == 3)
        for golden in frames {
            let raw = try bytes(fromHex: golden.hex)
            let frame = try FrameCodec.decode(raw)
            #expect(frame.cmd == SafeCommand.toggleHRBroadcast.rawValue)
            #expect(FrameCodec.encodeCommand(.toggleHRBroadcast, seq: frame.seq, payload: frame.payload) == raw)
        }
    }

    @Test func alarmFramesRoundTripAsSetAlarmTime() throws {
        let frames = try loadFrames().filter { $0.name.hasPrefix("set_alarm_") }
        #expect(frames.count == 7)
        for golden in frames {
            let raw = try bytes(fromHex: golden.hex)
            let frame = try FrameCodec.decode(raw)
            #expect(frame.cmd == SafeCommand.setAlarmTime.rawValue)
            #expect(FrameCodec.encodeCommand(.setAlarmTime, seq: frame.seq, payload: frame.payload) == raw)
        }
    }
}
