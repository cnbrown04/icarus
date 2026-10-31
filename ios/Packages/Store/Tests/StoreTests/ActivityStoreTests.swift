import Foundation
import GRDB
import Metrics
import Testing
@testable import Store

/// Activity detection and edits against stored minute rows. The profile is 36 years old in 2026 (Tanaka HRmax
/// about 183). A sleep session with 55 bpm resting HR supplies the resting HR, so the threshold is about 119 bpm.
@Suite("Activities: detection, manual recording, edits and tombstones (v9)")
struct ActivityStoreTests {
    private let minute = LocalTime.msPerMinute
    /// Mid-afternoon, so the span is clear of the night's sleep.
    private let origin = testNowMs - 3 * 60 * 60 * 1000

    /// The seeded store plus a resting-HR sleep session the night before `origin`.
    private func database() throws -> AppDatabase {
        let database = try seededDatabase()
        _ = try database.writer.write { db in
            let bandID = try String.fetchOne(db, sql: "SELECT id FROM band")
            let start = origin - 36 * 60 * 60 * 1000
            let end = origin - 28 * 60 * 60 * 1000
            try db.execute(sql: """
            INSERT INTO sleep_session (band_id, start_ms, end_ms, duration_s, resting_hr, contact_fraction, quality,
              record_count, algo_version, computed_at, is_nap)
            VALUES (?, ?, ?, 28800, 55, 1, 'good', 100, 1, 0, 0)
            """, arguments: [bandID, start, end])
        }
        return database
    }

    /// Minute rows from `origin`: one per minute at `bpm(index)`.
    private func storeMinutes(_ database: AppDatabase, count: Int, bpm: (Int) -> Int) throws {
        let rows = (0..<count).map { index in
            minuteRow(origin + Int64(index) * minute, hr: Double(bpm(index)))
        }
        // Save, not insert: a rewrite of the same minutes must replace them.
        _ = try database.writer.write { db in
            for row in rows {
                try row.save(db)
            }
        }
    }

    /// Detection over a window that starts an hour before `origin` and runs well past the data.
    private func detect(_ database: AppDatabase, nowMs: Int64 = testNowMs) throws -> Int {
        try database.writer.write { db in
            try db.detectActivities(from: origin - 60 * minute, to: origin + 6 * 60 * minute, in: chicago, computedAtMs: nowMs)
        }
    }

    private func live(_ database: AppDatabase) throws -> [ActivityRow] {
        try database.writer.read { db in
            try db.activities(from: origin - 60 * minute, to: origin + 6 * 60 * minute)
        }
    }

    // MARK: - Detection

    @Test func detectsAFortyMinuteRunAsAnAutoRow() throws {
        let database = try database()
        // 30 min at rest, a 40 min run, then 30 min at rest.
        try storeMinutes(database, count: 100) { index in (30..<70).contains(index) ? 150 : 60 }

        #expect(try detect(database) == 1)
        let rows = try live(database)
        let row = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(row.isAuto)
        #expect(row.activityKind == .other)
        #expect(row.startMs == origin + 30 * minute)
        #expect(row.endMs == origin + 70 * minute)
        #expect(row.algoVersion == ActivityDetector.algoVersion)
        // minuteRow sets hrMax to hr + 3.
        #expect(row.maxHR == 153)
        #expect((row.kcal ?? 0) > 0)
        #expect((row.strain ?? 0) > 0)
        #expect(row.zoneMinuteValues.count == 6)
        #expect(abs(row.zoneMinuteValues.reduce(0, +) - 40) < 1e-9)
    }

    @Test func redetectingTheSameMinutesWritesNothing() throws {
        let database = try database()
        try storeMinutes(database, count: 100) { index in (30..<70).contains(index) ? 150 : 60 }
        _ = try detect(database)
        #expect(try detect(database, nowMs: testNowMs + 60_000) == 0)
        #expect(try live(database).count == 1)
    }

    @Test func aTenMinuteWalkIsNotStored() throws {
        let database = try database()
        try storeMinutes(database, count: 100) { index in (30..<40).contains(index) ? 130 : 60 }
        #expect(try detect(database) == 0)
        #expect(try live(database).isEmpty)
    }

    @Test func staleAutoRowsAreRemovedWhenTheirBoutIsGone() throws {
        let database = try database()
        try storeMinutes(database, count: 100) { index in (30..<70).contains(index) ? 150 : 60 }
        _ = try detect(database)
        // The minutes are rewritten as rest, so the auto row has no bout behind it any more.
        try storeMinutes(database, count: 100) { _ in 60 }
        #expect(try detect(database) == 1)
        #expect(try live(database).isEmpty)
    }

    @Test func noProfileMeansNoDetection() throws {
        let database = try AppDatabase.inMemory()
        _ = try database.writer.write { db in
            try db.upsertBand(peripheralUUID: testPeripheral, name: "Band", seenAtMs: testNowMs)
        }
        try storeMinutes(database, count: 100) { index in (30..<70).contains(index) ? 150 : 60 }
        #expect(try detect(database) == 0)
    }

    // MARK: - Manual rows and edits

    @Test func aManualRowOwnsItsTimeAgainstDetection() throws {
        let database = try database()
        try storeMinutes(database, count: 100) { index in (30..<70).contains(index) ? 150 : 60 }
        _ = try database.writer.write { db in
            try db.saveManualActivity(kind: .run, name: "Track", startMs: origin + 30 * minute, endMs: origin + 70 * minute, computedAtMs: testNowMs)
        }
        #expect(try detect(database) == 0)
        let rows = try live(database)
        #expect(rows.count == 1)
        #expect(rows.first?.isAuto == false)
        #expect(rows.first?.name == "Track")
    }

    @Test func renamingAnAutoRowKeepsItThroughRedetection() throws {
        let database = try database()
        try storeMinutes(database, count: 100) { index in (30..<70).contains(index) ? 150 : 60 }
        _ = try detect(database)
        let id = try #require(try live(database).first?.id)
        try database.writer.write { db in
            try db.updateActivity(id: id, kind: .run, name: "  Hill repeats ", computedAtMs: testNowMs)
        }

        // Even with the minutes gone, the user's row stays: it is manual now.
        try storeMinutes(database, count: 100) { _ in 60 }
        _ = try detect(database)
        let row = try #require(try database.writer.read { try $0.activity(id: id) })
        #expect(row.activityKind == .run)
        #expect(row.name == "Hill repeats")
        #expect(row.source == "manual")
    }

    @Test func aDeletedAutoRowDoesNotReappear() throws {
        let database = try database()
        try storeMinutes(database, count: 100) { index in (30..<70).contains(index) ? 150 : 60 }
        _ = try detect(database)
        let id = try #require(try live(database).first?.id)
        try database.writer.write { db in
            try db.deleteActivity(id: id, computedAtMs: testNowMs)
        }
        #expect(try live(database).isEmpty)

        #expect(try detect(database, nowMs: testNowMs + minute) == 0)
        #expect(try live(database).isEmpty)
        // The tombstone is still there, so the span stays blocked.
        let tombstones = try database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM activity WHERE deleted_at IS NOT NULL")
        }
        #expect(tombstones == 1)
    }

    // MARK: - Manual recording

    @Test func savesAManualActivityWithTrimmedNameAndMetrics() throws {
        let database = try database()
        try storeMinutes(database, count: 100) { _ in 150 }
        let row = try database.writer.write { db in
            try db.saveManualActivity(kind: .cycle, name: "  Commute ", startMs: origin, endMs: origin + 20 * minute, computedAtMs: testNowMs)
        }
        #expect(row.source == "manual")
        #expect(row.activityKind == .cycle)
        #expect(row.name == "Commute")
        #expect(row.bandID != nil)
        #expect(abs((row.zoneMinuteValues.reduce(0, +)) - 20) < 1e-9)
        #expect(try live(database).map(\.id) == [row.id])
    }

    @Test func manualActivityWithoutHeartRateKeepsItsSpanWithoutMetrics() throws {
        let database = try database()
        let row = try database.writer.write { db in
            try db.saveManualActivity(kind: .yoga, name: nil, startMs: origin, endMs: origin + 30 * minute, computedAtMs: testNowMs)
        }
        #expect(row.avgHR == nil)
        #expect(row.strain == nil)
        #expect(row.name == nil)
    }

    @Test func rejectsAnEmptyRange() throws {
        let database = try database()
        #expect(throws: ActivityStoreError.invalidRange) {
            _ = try database.writer.write { db in
                try db.saveManualActivity(kind: .run, name: nil, startMs: origin, endMs: origin, computedAtMs: testNowMs)
            }
        }
    }

    @Test func editingAndDeletingAMissingActivityThrowsNotFound() throws {
        let database = try database()
        #expect(throws: ActivityStoreError.notFound) {
            _ = try database.writer.write { db in
                try db.updateActivity(id: "missing", kind: .run, name: nil, computedAtMs: testNowMs)
            }
        }
        #expect(throws: ActivityStoreError.notFound) {
            _ = try database.writer.write { db in
                try db.deleteActivity(id: "missing", computedAtMs: testNowMs)
            }
        }
    }

    @Test func activitiesReadsOnlyLiveRowsInRange() throws {
        let database = try database()
        let inside = try database.writer.write { db in
            try db.saveManualActivity(kind: .walk, name: nil, startMs: origin, endMs: origin + 20 * minute, computedAtMs: testNowMs)
        }
        _ = try database.writer.write { db in
            try db.saveManualActivity(kind: .walk, name: nil, startMs: origin + 3 * 60 * minute, endMs: origin + 3 * 60 * minute + 20 * minute, computedAtMs: testNowMs)
        }
        let deleted = try database.writer.write { db in
            try db.saveManualActivity(kind: .walk, name: nil, startMs: origin + 40 * minute, endMs: origin + 60 * minute, computedAtMs: testNowMs)
        }
        try database.writer.write { db in
            try db.deleteActivity(id: deleted.id, computedAtMs: testNowMs)
        }
        let rows = try database.writer.read { db in
            try db.activities(from: origin, to: origin + 2 * 60 * minute)
        }
        #expect(rows.map(\.id) == [inside.id])
    }

    // MARK: - Schema

    @Test func v9CreatesTheActivityTable() throws {
        let database = try AppDatabase.inMemory()
        let columns = try database.writer.read { db in
            try db.columns(in: "activity").map(\.name)
        }
        for expected in ["id", "band_id", "start_ms", "end_ms", "kind", "source", "name", "strain", "avg_hr",
                         "max_hr", "kcal", "zone_minutes", "algo_version", "updated_at", "deleted_at"] {
            #expect(columns.contains(expected))
        }
    }
}
