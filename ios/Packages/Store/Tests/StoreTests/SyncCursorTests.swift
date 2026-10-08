import Foundation
import GRDB
import Testing
@testable import Store

struct SyncCursorTests {
    private func seedReadings(_ count: Int, into database: AppDatabase) throws {
        let readings = (0..<count).map { index in
            Database.Reading(peripheralUUID: testPeripheral, tsMs: Int64(index + 1) * 1000, bpm: 60, contact: nil, rr: [])
        }
        _ = try database.writer.write { try $0.insertReadings(readings) }
    }

    @Test func cursorStartsAtZero() throws {
        let database = try AppDatabase.inMemory()
        #expect(try database.writer.read { try $0.syncCursor(.hrSample) } == 0)
    }

    @Test func cursorOnlyMovesForward() throws {
        let database = try AppDatabase.inMemory()
        let positions = try database.writer.write { db -> [Int64] in
            try db.advanceSyncCursor(.hrSample, to: 5, succeededAtMs: 100)
            try db.advanceSyncCursor(.hrSample, to: 3, succeededAtMs: 200)
            return [try db.syncCursor(.hrSample)]
        }
        #expect(positions == [5])
    }

    @Test func cursorsAreTrackedPerStream() throws {
        let database = try AppDatabase.inMemory()
        _ = try database.writer.write { db in
            try db.advanceSyncCursor(.rrInterval, to: 9, succeededAtMs: 1)
        }
        let values = try database.writer.read { db in
            (try db.syncCursor(.rrInterval), try db.syncCursor(.hrSample))
        }
        #expect(values.0 == 9)
        #expect(values.1 == 0)
    }

    @Test func pendingRowsStartAfterTheCursorInRowidOrder() throws {
        let database = try seededDatabase()
        try seedReadings(5, into: database)
        let firstPage = try database.writer.read { try $0.pendingHeartRateRows(after: 0, limit: 2) }
        #expect(firstPage.map(\.tsMs) == [1000, 2000])

        _ = try database.writer.write { try $0.advanceSyncCursor(.hrSample, to: firstPage.last!.rowid, succeededAtMs: 5) }
        let cursor = try database.writer.read { try $0.syncCursor(.hrSample) }
        let next = try database.writer.read { try $0.pendingHeartRateRows(after: cursor, limit: 10) }
        #expect(next.map(\.tsMs) == [3000, 4000, 5000])
    }

    @Test func pendingMinuteRowsUseSyncRevAsTheCursor() throws {
        let database = try AppDatabase.inMemory()
        try insertMinuteRows([
            minuteRow(0, syncRev: 1),
            minuteRow(60_000, syncRev: 4),
            minuteRow(120_000, syncRev: 2),
        ], into: database)
        let rows = try database.writer.read { try $0.pendingMinuteMetricRows(afterSyncRev: 1, limit: 10) }
        #expect(rows.map(\.syncRev) == [2, 4])
    }

    @Test func batchLogRecordsAndFiltersByStatus() throws {
        let database = try AppDatabase.inMemory()
        _ = try database.writer.write { db in
            try db.recordSyncBatch(id: "a", createdAtMs: 1, rows: 10, status: "pending")
            try db.recordSyncBatch(id: "b", createdAtMs: 2, rows: 5, status: "pending")
            try db.updateSyncBatch(id: "b", status: "rejected", httpStatus: 422, error: "schema")
        }
        let rejected = try database.writer.read { try $0.syncBatches(status: "rejected", limit: 10) }
        #expect(rejected.map(\.batchID) == ["b"])
        #expect(rejected.first?.httpStatus == 422)
        let all = try database.writer.read { try $0.syncBatches(limit: 10) }
        #expect(all.map(\.batchID) == ["b", "a"])
    }
}
