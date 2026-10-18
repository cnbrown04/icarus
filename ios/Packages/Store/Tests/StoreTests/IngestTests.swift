import Foundation
import GRDB
import Metrics
import Testing
@testable import Store

struct IngestTests {
    @Test func acceptsBpmAtTheRangeEdges() {
        var preparer = ReadingPreparer()
        #expect(preparer.prepare(peripheralUUID: testPeripheral, tsMs: 1, bpm: 20, contact: nil, rrMs: []) != nil)
        #expect(preparer.prepare(peripheralUUID: testPeripheral, tsMs: 2, bpm: 250, contact: nil, rrMs: []) != nil)
    }

    @Test func dropsBpmOutsideTheRange() {
        var preparer = ReadingPreparer()
        #expect(preparer.prepare(peripheralUUID: testPeripheral, tsMs: 1, bpm: 19, contact: nil, rrMs: [800]) == nil)
        #expect(preparer.prepare(peripheralUUID: testPeripheral, tsMs: 2, bpm: 251, contact: nil, rrMs: []) == nil)
    }

    @Test func flagsRRByRangeAndLocalMedian() throws {
        var preparer = ReadingPreparer()
        let reading = try required(preparer.prepare(
            peripheralUUID: testPeripheral, tsMs: 1, bpm: 60, contact: .detected,
            rrMs: [800, 200, 2001, 810]
        ))
        #expect(reading.rr.map(\.accepted) == [true, false, false, true])
        #expect(reading.contact == true)
    }

    @Test func rejectsASpikeAgainstTheLocalMedian() throws {
        var preparer = ReadingPreparer()
        let reading = try required(preparer.prepare(
            peripheralUUID: testPeripheral, tsMs: 1, bpm: 60, contact: nil,
            rrMs: [800, 800, 800, 1200, 810]
        ))
        #expect(reading.rr.map(\.accepted) == [true, true, true, false, true])
        #expect(reading.contact == nil)
    }

    @Test func carriesAcceptedRRAcrossNotifications() throws {
        var preparer = ReadingPreparer()
        _ = preparer.prepare(peripheralUUID: testPeripheral, tsMs: 1, bpm: 60, contact: nil, rrMs: [800, 800])
        let next = try required(preparer.prepare(
            peripheralUUID: testPeripheral, tsMs: 2, bpm: 60, contact: nil, rrMs: [1300]
        ))
        #expect(next.rr.map(\.accepted) == [false])
    }

    @Test func contactMapsNotDetectedToFalse() throws {
        var preparer = ReadingPreparer()
        let prepared = preparer.prepare(peripheralUUID: testPeripheral, tsMs: 1, bpm: 60, contact: .notDetected, rrMs: [])
        let reading = try required(prepared)
        #expect(reading.contact == false)
    }

    @Test func insertIsIdempotentPerKey() throws {
        let database = try AppDatabase.inMemory()
        let reading = Database.Reading(
            peripheralUUID: testPeripheral,
            tsMs: 1_000,
            bpm: 61,
            contact: true,
            rr: [.init(seq: 0, rrMs: 800, accepted: true), .init(seq: 1, rrMs: 900, accepted: false)]
        )
        let first = try database.writer.write { try $0.insertReadings([reading]) }
        let second = try database.writer.write { try $0.insertReadings([reading]) }
        #expect(first == Database.InsertCounts(heartRate: 1, rrIntervals: 2))
        #expect(second == Database.InsertCounts(heartRate: 0, rrIntervals: 0))

        let counts = try database.writer.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hr_sample"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rr_interval"))
        }
        #expect(counts.0 == 1)
        #expect(counts.1 == 2)
    }

    @Test func insertCreatesOneBandRowPerPeripheral() throws {
        let database = try AppDatabase.inMemory()
        let readings = (0..<5).map { index in
            Database.Reading(peripheralUUID: testPeripheral, tsMs: Int64(index), bpm: 60, contact: nil, rr: [])
        }
        _ = try database.writer.write { try $0.insertReadings(readings) }
        let bands = try database.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM band") }
        #expect(bands == 1)
    }

    @Test func bandUpsertKeepsIdAndNameWhenNameIsNil() throws {
        let database = try AppDatabase.inMemory()
        let (first, second, named) = try database.writer.write { db -> (String, String, String?) in
            let first = try db.upsertBand(peripheralUUID: testPeripheral, name: "Band A", seenAtMs: 1)
            let second = try db.upsertBand(peripheralUUID: testPeripheral, name: nil, seenAtMs: 2)
            let name = try String.fetchOne(db, sql: "SELECT name FROM band")
            return (first, second, name)
        }
        #expect(first == second)
        #expect(named == "Band A")
    }

    @Test func bandEventIsIgnoredWhenDuplicated() throws {
        let database = try seededDatabase()
        let bandID = try database.writer.read { try String.fetchOne($0, sql: "SELECT id FROM band") ?? "" }
        let (first, second) = try database.writer.write { db -> (Bool, Bool) in
            let first = try db.insertBandEvent(bandID: bandID, tsMs: 5, kind: "wrist_on", payload: nil)
            let second = try db.insertBandEvent(bandID: bandID, tsMs: 5, kind: "wrist_on", payload: nil)
            return (first, second)
        }
        #expect(first)
        #expect(!second)
    }
}
