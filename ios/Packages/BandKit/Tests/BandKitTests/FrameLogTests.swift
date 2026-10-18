import BandKit
import BandProtocol
import Foundation
import Testing

@Suite struct FrameLogTests {
    private let t0 = Date(timeIntervalSince1970: 1_791_382_500)

    @Test func keepsHeartRateAndWhoopNotifyCharacteristicsOnly() {
        var log = FrameLog()
        log.append(characteristic: "2A37", bytes: [0x16, 60, 0, 4], at: t0)
        log.append(characteristic: "2a29", bytes: Array("WHOOP-SERIAL".utf8), at: t0)
        log.append(characteristic: "2a19", bytes: [100], at: t0)
        log.append(characteristic: "61080002", bytes: [0xAA], at: t0)
        log.append(characteristic: "61080003", bytes: [0xAA, 0x01], at: t0)
        #expect(log.entries.map(\.characteristic) == ["2a37", "61080003"])
    }

    @Test func ringDropsTheOldestEntriesBeyondCapacity() {
        var log = FrameLog(capacity: 3)
        for second in 0 ..< 5 {
            log.append(characteristic: "2a37", bytes: [0x16, UInt8(60 + second), 0, 4], at: t0.addingTimeInterval(Double(second)))
        }
        #expect(log.count == 3)
        #expect(log.entries.map(\.id) == [2, 3, 4])
        #expect(log.entries.first?.bytes[1] == 62)
    }

    @Test func latestReturnsNewestFirstWithinLimit() {
        var log = FrameLog()
        for second in 0 ..< 4 {
            log.append(characteristic: "2a37", bytes: [UInt8(second)], at: t0.addingTimeInterval(Double(second)))
        }
        #expect(log.latest(2).map(\.id) == [3, 2])
        #expect(log.latest(10).count == 4)
        #expect(log.latest(0).isEmpty)
    }

    @Test func hexIsLowercaseAndPadded() {
        let entry = FrameLog.Entry(id: 0, date: t0, characteristic: "2a37", bytes: [0x16, 0x3C, 0x00, 0x0A])
        #expect(entry.hex == "163c000a")
    }

    @Test func ndjsonLineUsesTheFixtureFormat() {
        var log = FrameLog()
        log.append(characteristic: "2a37", bytes: [0x16, 60, 0, 4], at: Date(timeIntervalSince1970: 100.5))
        #expect(log.ndjson(since: .distantPast) == "{\"t\":100.5,\"char\":\"2a37\",\"hex\":\"163c0004\"}\n")
    }

    @Test func ndjsonOnlyCoversTheRequestedWindow() {
        var log = FrameLog()
        log.append(characteristic: "2a37", bytes: [0x16, 60, 0, 4], at: Date(timeIntervalSince1970: 100))
        log.append(characteristic: "2a37", bytes: [0x16, 61, 0, 4], at: Date(timeIntervalSince1970: 700))
        let lines = log.ndjson(since: Date(timeIntervalSince1970: 500)).split(separator: "\n")
        #expect(lines.count == 1)
        #expect(lines.first?.contains("163d0004") == true)
    }

    @Test func exportRoundTripsThroughTheFixtureParser() {
        var log = FrameLog()
        for second in 0 ..< 5 {
            log.append(characteristic: "2a37", bytes: [0x16, UInt8(60 + second), 0, 4], at: t0.addingTimeInterval(Double(second)))
        }
        let parsed = NDJSONFixture.parse(log.ndjson(since: .distantPast))
        #expect(parsed.skippedLineCount == 0)
        #expect(parsed.frames.map(\.measurement.bpm) == [60, 61, 62, 63, 64])
        #expect(parsed.frames.map(\.timestamp) == [0, 1, 2, 3, 4].map { t0.timeIntervalSince1970 + Double($0) })
    }

    @Test func exportNeverContainsDeviceInformation() {
        var log = FrameLog()
        log.append(characteristic: "2a37", bytes: [0x16, 60, 0, 4], at: t0)
        log.append(characteristic: "2a29", bytes: Array("SERIAL-123".utf8), at: t0)
        let text = log.ndjson(since: .distantPast)
        #expect(!text.contains("2a29"))
        #expect(!text.contains("SERIAL"))
        #expect(text.split(separator: "\n").count == 1)
    }

    @Test func exportWindowIsTenMinutes() {
        #expect(FrameLog.exportWindow == 600)
    }
}

@Suite struct GATTShortIDTests {
    @Test func standardCharacteristicUsesFourDigits() {
        #expect(GATTShortID.make("2A37") == "2a37")
    }

    @Test func bluetoothBaseUUIDUsesTheSixteenBitPart() {
        #expect(GATTShortID.make("0000180D-0000-1000-8000-00805F9B34FB") == "180d")
    }

    @Test func whoopCustomUUIDUsesEightDigits() {
        #expect(GATTShortID.make("61080003-8D6D-82B8-614A-1C8CB0F8DCC6") == "61080003")
        #expect(GATTShortID.make("61080003-8d6d-82b8-614a-1c8cb0f8dcc6") == "61080003")
    }

    @Test func unknownUUIDIsLowercasedWhole() {
        #expect(GATTShortID.make("12345678-ABCD-4000-8000-000000000001") == "12345678-abcd-4000-8000-000000000001")
    }
}
