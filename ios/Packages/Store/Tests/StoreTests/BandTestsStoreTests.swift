import Foundation
import GRDB
import Testing
@testable import Store

@Suite("Band tests store")
struct BandTestsStoreTests {
    @Test func eventsAreStoredWithTheirIdAndPayload() throws {
        let database = try seededDatabase()
        try database.writer.write { db in
            try db.recordBandEvent(peripheralUUID: testPeripheral, tsMs: 1_000, kind: "event_42",
                                   payload: #"{"id":42,"hex":"0a0b"}"#)
            try db.recordBandEvent(peripheralUUID: testPeripheral, tsMs: 2_000, kind: "charging_on",
                                   payload: #"{"id":7,"hex":""}"#)
        }
        let events = try database.writer.read { try $0.bandEvents() }
        #expect(events.map(\.kind) == ["charging_on", "event_42"])
        #expect(events.last?.id == 42)
        #expect(events.last?.hex == "0a0b")
        let windowed = try database.writer.read { try $0.bandEvents(fromMs: 1_500, toMs: 3_000) }
        #expect(windowed.map(\.kind) == ["charging_on"])
    }

    @Test func marksGroupIntoRunsNewestFirst() throws {
        let database = try seededDatabase()
        try database.writer.write { db in
            try db.saveBandTestMark(BandTestMark(runID: "a", step: 1, label: "off", startMs: 10, endMs: 20, skipped: false))
            try db.saveBandTestMark(BandTestMark(runID: "a", step: 0, label: "still", startMs: 0, endMs: 10, skipped: false))
            try db.saveBandTestMark(BandTestMark(runID: "b", step: 0, label: "still", startMs: 100, endMs: 110, skipped: true))
        }
        let runs = try database.writer.read { try $0.bandTestRuns() }
        #expect(runs.map { $0.first?.runID } == ["b", "a"])
        #expect(runs[1].map(\.step) == [0, 1])
        #expect(runs[0].first?.skipped == true)
    }

    @Test func samplesCarryTheCandidateChannels() throws {
        let database = try seededDatabase()
        try database.writer.write { db in
            try db.insertHistoricalSamples([
                Database.HistoricalSample(peripheralUUID: testPeripheral, tsMs: 5_000, version: 24, bpm: 60, contact: true,
                                          rrMs: [1_000], ppgGreen: 18_000, skinTempRaw: 600, gravityX: 0, gravityY: 0,
                                          gravityZ: 1, ambientDrive: 640, ledDrive1: 300, ledDrive2: 1_400, aux92Raw: 777),
            ])
        }
        let samples = try database.writer.read { try $0.bandTestSamples(fromMs: 0, toMs: 10_000) }
        let sample = try #require(samples.first)
        #expect(sample.frame72 == 600)
        #expect(sample.frame76 == 300)
        #expect(sample.frame92 == 777)
        #expect(sample.ppgGreen == 18_000)
        #expect(sample.rrMs == [1_000])
        #expect(sample.gravity?.z == 1)
    }
}

@Suite("Band tests capture")
struct BandTestsCaptureTests {
    @Test func readingsAndFramesRoundTrip() throws {
        let database = try seededDatabase()
        try database.writer.write { db in
            try db.saveBandTestMark(BandTestMark(runID: "r", step: 22, label: "room", startMs: 0, endMs: 10,
                                                 skipped: false, reading: 22.5))
            try db.saveBandTestFrames(runID: "r", [BandTestFrame(tsMs: 1, seq: 21, payload: [1, 2, 3])])
            try db.saveBandTestFrames(runID: "r", [BandTestFrame(tsMs: 2, seq: 10, payload: [4])])
        }
        let runs = try database.writer.read { try $0.bandTestRuns() }
        #expect(runs.first?.first?.reading == 22.5)
        let frames = try database.writer.read { try $0.bandTestFrames(runID: "r") }
        #expect(frames == [BandTestFrame(tsMs: 1, seq: 21, payload: [1, 2, 3]), BandTestFrame(tsMs: 2, seq: 10, payload: [4])])
    }
}
