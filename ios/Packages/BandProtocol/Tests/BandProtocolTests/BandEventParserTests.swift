import Foundation
import Testing
@testable import BandProtocol

@Suite("Band event parsing")
struct BandEventParserTests {
    private func event(_ id: UInt8, payload: [UInt8] = []) throws -> Frame {
        try FrameCodec.decode(FrameCodec.encode(type: PacketType.event.rawValue, seq: 1, cmd: id, payload: payload))
    }

    @Test func planEventIDsMapToNamedKinds() throws {
        let expected: [(UInt8, BandEventKind)] = [
            (3, .batteryLevel), (7, .chargingOn), (8, .chargingOff), (9, .wristOn), (10, .wristOff),
            (13, .rtcLost), (14, .doubleTap), (23, .bleBonded), (57, .strapDrivenAlarmExecuted), (60, .hapticsFired),
        ]
        for (id, kind) in expected {
            #expect(BandEventParser.parse(try event(id)) == kind, "event \(id)")
        }
    }

    @Test func undocumentedIDsAreKeptAsUnknown() throws {
        for id: UInt8 in [0, 1, 21, 24, 33, 34, 200] {
            #expect(BandEventParser.parse(try event(id)) == .unknown(id))
        }
    }

    @Test func nonEventPacketsAreNotEvents() throws {
        let response = try FrameCodec.decode(FrameCodec.encode(type: PacketType.commandResponse.rawValue, seq: 1, cmd: 3, payload: []))
        #expect(BandEventParser.parse(response) == nil)
    }

    @Test func goldenEventFramesParse() throws {
        // shared/golden/frames.json (S8): event_seq76_rec07 is cmd 7 (charging on), event_seq5b_rec21 is cmd 33.
        let charging = try FrameCodec.decode(Array(hex: "aa100057307607001c5f6866a0050000ac1a4bdc"))
        #expect(BandEventParser.parse(charging) == .chargingOn)
        let undocumented = try FrameCodec.decode(Array(hex: "aa100057305b21003f32696668540000b0b2435b"))
        #expect(BandEventParser.parse(undocumented) == .unknown(33))
    }

    @Test func eventPayloadDoesNotChangeTheKind() throws {
        #expect(BandEventParser.parse(try event(9, payload: [0, 1, 2, 3, 4])) == .wristOn)
    }
}

private extension Array where Element == UInt8 {
    init(hex: String) {
        self = stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start ..< hex.index(start, offsetBy: 2)], radix: 16)!
        }
    }
}
