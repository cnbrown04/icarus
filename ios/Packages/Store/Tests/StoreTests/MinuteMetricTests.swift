import Foundation
import GRDB
import Metrics
import Testing
@testable import Store

struct MinuteMetricTests {
    private let start: Int64 = 1_700_000_040_000

    @Test func firstWriteInsertsEveryRowWithRevisionsInOrder() throws {
        let database = try AppDatabase.inMemory()
        let metrics = calculatedMinutes(from: start, count: 3, bpm: 60)
        let changed = try database.writer.write { try $0.upsertMinuteMetrics(metrics, computedAtMs: 10) }
        #expect(changed == 3)
        let revisions = try database.writer.read { db in
            try MinuteMetricRow.fetchAll(db).map(\.syncRev)
        }
        #expect(revisions == [1, 2, 3])
    }

    @Test func unchangedValuesDoNotBumpSyncRev() throws {
        let database = try AppDatabase.inMemory()
        let metrics = calculatedMinutes(from: start, count: 2, bpm: 60)
        _ = try database.writer.write { try $0.upsertMinuteMetrics(metrics, computedAtMs: 10) }
        let changed = try database.writer.write { try $0.upsertMinuteMetrics(metrics, computedAtMs: 99) }
        #expect(changed == 0)

        let rows = try database.writer.read { try MinuteMetricRow.fetchAll($0) }
        #expect(rows.map(\.syncRev) == [1, 2])
        #expect(rows.map(\.computedAt) == [10, 10])
    }

    @Test func changedValueBumpsOnlyThatRowToTheNextRevision() throws {
        let database = try AppDatabase.inMemory()
        _ = try database.writer.write { try $0.upsertMinuteMetrics(calculatedMinutes(from: start, count: 2, bpm: 60), computedAtMs: 10) }

        // Minute 1 changes; minute 0 keeps its values, so only one row is rewritten.
        let laterMinute = Array(calculatedMinutes(from: start, count: 2, bpm: 70).dropFirst())
        let changed = try database.writer.write { try $0.upsertMinuteMetrics(laterMinute, computedAtMs: 20) }
        #expect(changed == 1)

        let rows = try database.writer.read { try MinuteMetricRow.fetchAll($0) }
        #expect(rows[0].syncRev == 1)
        #expect(rows[1].syncRev == 3)
        #expect(rows[1].hrAvg == 70)
    }

    @Test func revisionIsAboveEveryExistingRowAfterAChange() throws {
        let database = try AppDatabase.inMemory()
        try insertMinuteRows([minuteRow(start, syncRev: 40), minuteRow(start + 60_000, syncRev: 7)], into: database)
        let changed = try database.writer.write {
            try $0.upsertMinuteMetrics(calculatedMinutes(from: start + 60_000, count: 1, bpm: 90), computedAtMs: 1)
        }
        #expect(changed == 1)
        let revision = try database.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT sync_rev FROM minute_metric WHERE minute_ms = ?", arguments: [start + 60_000])
        }
        #expect(revision == 41)
    }

    @Test func storesOneIntegerAlgoVersion() throws {
        let database = try AppDatabase.inMemory()
        _ = try database.writer.write { try $0.upsertMinuteMetrics(calculatedMinutes(from: start, count: 1, bpm: 60), computedAtMs: 1) }
        let version = try database.writer.read { try Int.fetchOne($0, sql: "SELECT algo_version FROM minute_metric") }
        #expect(version == AlgoVersion.current.storedValue)
        #expect(version == 1)
    }
}
