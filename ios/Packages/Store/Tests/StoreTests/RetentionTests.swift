import Foundation
import GRDB
import Testing
@testable import Store

struct RetentionTests {
    private let day: Int64 = 86_400_000
    private let now: Int64 = 1_800_000_000_000

    private func insertHeartRate(_ timestamps: [Int64], into database: AppDatabase) throws {
        let readings = timestamps.map { ts in
            Database.Reading(peripheralUUID: testPeripheral, tsMs: ts, bpm: 60, contact: nil, rr: [])
        }
        _ = try database.writer.write { try $0.insertReadings(readings) }
    }

    @Test func rawRowsSurviveWithoutAnAcknowledgedCursor() throws {
        let database = try AppDatabase.inMemory()
        try insertHeartRate([now - 40 * day, now - 35 * day, now - day], into: database)
        let result = try database.writer.write { try $0.purgeExpired(nowMs: now) }
        #expect(result.heartRateRows == 0)
        #expect(try database.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM hr_sample") } == 3)
    }

    @Test func rawRowsOlderThanThirtyDaysAndAcknowledgedAreDeleted() throws {
        let database = try AppDatabase.inMemory()
        try insertHeartRate([now - 40 * day, now - 31 * day, now - 29 * day, now - day], into: database)
        let result = try database.writer.write { db -> RetentionResult in
            let lastRowid = try Int64.fetchOne(db, sql: "SELECT MAX(rowid) FROM hr_sample") ?? 0
            try db.advanceSyncCursor(.hrSample, to: lastRowid, succeededAtMs: now)
            return try db.purgeExpired(nowMs: now)
        }
        #expect(result.heartRateRows == 2)
        let remaining = try database.writer.read { try Int64.fetchAll($0, sql: "SELECT ts_ms FROM hr_sample ORDER BY ts_ms") }
        #expect(remaining == [now - 29 * day, now - day])
    }

    @Test func unacknowledgedRowsAreKeptEvenWhenOld() throws {
        let database = try AppDatabase.inMemory()
        try insertHeartRate([now - 40 * day, now - 39 * day, now - day], into: database)
        _ = try database.writer.write { db in
            try db.advanceSyncCursor(.hrSample, to: 1, succeededAtMs: now)
        }
        let result = try database.writer.write { try $0.purgeExpired(nowMs: now) }
        #expect(result.heartRateRows == 1)
        #expect(try database.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM hr_sample") } == 2)
    }

    @Test func newestRowIsKeptSoRowidsNeverRewindBelowTheCursor() throws {
        let database = try AppDatabase.inMemory()
        try insertHeartRate([now - 40 * day, now - 39 * day], into: database)
        _ = try database.writer.write { db in
            try db.advanceSyncCursor(.hrSample, to: 2, succeededAtMs: now)
        }
        let result = try database.writer.write { try $0.purgeExpired(nowMs: now) }
        #expect(result.heartRateRows == 1)
        let newest = try database.writer.read { try Int64.fetchOne($0, sql: "SELECT MAX(rowid) FROM hr_sample") }
        #expect(newest == 2)

        // A new row gets a rowid above the cursor, so it still syncs.
        try insertHeartRate([now], into: database)
        let fresh = try database.writer.read { try $0.pendingHeartRateRows(after: 2, limit: 10) }
        #expect(fresh.map(\.tsMs) == [now])
    }

    @Test func rrRowsFollowTheirOwnCursor() throws {
        let database = try AppDatabase.inMemory()
        let old = Database.Reading(
            peripheralUUID: testPeripheral, tsMs: now - 40 * day, bpm: 60, contact: nil,
            rr: [.init(seq: 0, rrMs: 800, accepted: true)]
        )
        let recent = Database.Reading(peripheralUUID: testPeripheral, tsMs: now - day, bpm: 60, contact: nil, rr: [
            .init(seq: 0, rrMs: 810, accepted: true),
        ])
        _ = try database.writer.write { try $0.insertReadings([old, recent]) }
        _ = try database.writer.write { try $0.advanceSyncCursor(.rrInterval, to: 2, succeededAtMs: now) }
        let result = try database.writer.write { try $0.purgeExpired(nowMs: now) }
        #expect(result.rrRows == 1)
        #expect(result.heartRateRows == 0)
    }

    @Test func minuteRowsKeepFourHundredDays() throws {
        let database = try AppDatabase.inMemory()
        try insertMinuteRows([
            minuteRow(now - 401 * day, syncRev: 1),
            minuteRow(now - 399 * day, syncRev: 2),
        ], into: database)
        let result = try database.writer.write { try $0.purgeExpired(nowMs: now) }
        #expect(result.minuteRows == 1)
        #expect(try database.writer.read { try Int64.fetchOne($0, sql: "SELECT minute_ms FROM minute_metric") } == now - 399 * day)
    }

    @Test func rawFramesKeepSeventyTwoHours() throws {
        let database = try AppDatabase.inMemory()
        let hour: Int64 = 3_600_000
        _ = try database.writer.write { db in
            try db.execute(sql: "INSERT INTO raw_frame (ts_ms, char, hex) VALUES (?, '2a37', 'aa')", arguments: [now - 73 * hour])
            try db.execute(sql: "INSERT INTO raw_frame (ts_ms, char, hex) VALUES (?, '2a37', 'bb')", arguments: [now - 71 * hour])
        }
        let result = try database.writer.write { try $0.purgeExpired(nowMs: now) }
        #expect(result.rawFrameRows == 1)
    }
}
