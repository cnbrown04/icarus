import Foundation
import GRDB
import Metrics
import Testing
@testable import Store

struct MetricsWorkerTests {
    private func storeOneMinuteSamples(into database: AppDatabase, endingAt nowMs: Int64, minutes: Int, bpm: Int) throws {
        let start = nowMs - Int64(minutes) * LocalTime.msPerMinute
        let readings = (0..<(minutes * 60)).map { index in
            Database.Reading(
                peripheralUUID: testPeripheral,
                tsMs: start + Int64(index) * 1000,
                bpm: bpm,
                contact: true,
                rr: []
            )
        }
        _ = try database.writer.write { try $0.insertReadings(readings) }
    }

    @Test func doesNothingWithoutACompleteProfile() async throws {
        let database = try AppDatabase.inMemory()
        let worker = MetricsWorker(database: database)
        let result = try await worker.recompute(nowMs: testNowMs)
        #expect(result == MetricsWorker.Result(changedRows: 0, ran: false))
    }

    @Test func computesClosedMinutesFromStoredSamples() async throws {
        let database = try seededDatabase()
        try storeOneMinuteSamples(into: database, endingAt: testNowMs, minutes: 30, bpm: 60)
        let worker = MetricsWorker(database: database)

        let first = try await worker.recompute(nowMs: testNowMs)
        #expect(first.ran)
        #expect(first.changedRows == 30)

        let rows = try await database.writer.read { try $0.minuteMetricRows(from: testNowMs - 10 * 60_000, to: testNowMs) }
        #expect(rows.count == 10)
        #expect(rows.allSatisfy { $0.hrAvg == 60 && $0.hrN == 60 })
        #expect(rows.allSatisfy { $0.kcal > 0 && $0.kcalEstimated == false })
    }

    @Test func secondRunOnTheSameInputsChangesNothing() async throws {
        let database = try seededDatabase()
        try storeOneMinuteSamples(into: database, endingAt: testNowMs, minutes: 30, bpm: 60)
        let worker = MetricsWorker(database: database)
        _ = try await worker.recompute(nowMs: testNowMs)
        let second = try await worker.recompute(nowMs: testNowMs)
        #expect(second.ran)
        #expect(second.changedRows == 0)
    }

    @Test func newSamplesUpdateTheMinutesInTheLookback() async throws {
        let database = try seededDatabase()
        try storeOneMinuteSamples(into: database, endingAt: testNowMs, minutes: 12, bpm: 60)
        let worker = MetricsWorker(database: database)
        _ = try await worker.recompute(nowMs: testNowMs)

        let later = testNowMs + 60_000
        _ = try await database.writer.write { db in
            let readings = (0..<60).map { index in
                Database.Reading(peripheralUUID: testPeripheral, tsMs: testNowMs + Int64(index) * 1000, bpm: 90, contact: true, rr: [])
            }
            try db.insertReadings(readings)
        }
        let result = try await worker.recompute(nowMs: later)
        #expect(result.changedRows >= 1)
        let latest = try await database.writer.read { try $0.minuteMetricRows(from: testNowMs, to: testNowMs + 60_000) }
        #expect(latest.first?.hrAvg == 90)
    }

    /// A drained batch can span hours. The range backfill must produce a minute row for every
    /// minute it covers, not just the equivalent of the worker's short launch lookback.
    @Test func rangeBackfillCoversEveryDrainedMinute() async throws {
        let database = try seededDatabase()
        // Four hours of samples ending an hour before "now", so every minute has closed.
        let end = testNowMs - 60 * LocalTime.msPerMinute
        let start = end - 4 * 60 * LocalTime.msPerMinute
        try storeOneMinuteSamples(into: database, endingAt: end, minutes: 240, bpm: 60)
        let worker = MetricsWorker(database: database)

        let result = try await worker.recomputeBackfill(fromMs: start, toMs: end - 1, nowMs: testNowMs)
        #expect(result.ran)
        let rows = try await database.writer.read {
            try $0.minuteMetricRows(from: start, to: end)
        }
        #expect(rows.count == 240, "every drained minute gets a row, not only the last 30 minutes")
        #expect(rows.allSatisfy { $0.hrAvg == 60 && $0.hrN == 60 })

        // Replaying the same drain range is idempotent.
        let second = try await worker.recomputeBackfill(fromMs: start, toMs: end - 1, nowMs: testNowMs)
        #expect(second.ran)
        #expect(second.changedRows == 0)
    }

    /// The newest minute is recomputed only once it has closed at `nowMs`; the regular ingest
    /// lookback owns the still-open minute.
    @Test func rangeBackfillSkipsAnUnclosedMinute() async throws {
        let database = try seededDatabase()
        let end = testNowMs - 10 * LocalTime.msPerMinute
        let start = end - 2 * LocalTime.msPerMinute
        try storeOneMinuteSamples(into: database, endingAt: end, minutes: 2, bpm: 60)
        // A sample in the minute starting at `end`, which is still open at `nowMs`.
        try await database.writer.write { db in
            try db.insertReadings([
                Database.Reading(
                    peripheralUUID: testPeripheral,
                    tsMs: end + 1_000,
                    bpm: 60,
                    contact: true,
                    rr: []
                ),
            ])
        }
        let worker = MetricsWorker(database: database)

        let result = try await worker.recomputeBackfill(
            fromMs: start,
            toMs: end + 1_000,
            nowMs: end + 30_000
        )
        #expect(result.ran)
        let rows = try await database.writer.read {
            try $0.minuteMetricRows(from: start, to: end + LocalTime.msPerMinute)
        }
        #expect(rows.count == 2, "the two closed minutes")
        #expect(rows.last?.minuteMs == end - LocalTime.msPerMinute)
    }

    @Test func rebuiltWindowsCarryTheStoredRMSSDOnlyOnceEach() {
        let rows = [
            minuteRow(0, hr: 60, rmssd: 45),
            minuteRow(60_000, hr: 62, rmssd: 45),
            minuteRow(300_000, hr: 70, rmssd: nil),
        ]
        let windows = FiveMinuteWindow.rebuilt(from: rows)
        #expect(windows.map(\.startMs) == [0, 300_000])
        #expect(windows[0].valid)
        #expect(windows[0].rmssd == 45)
        #expect(windows[1].valid == false)
    }

    @Test func nightWindowCountsOnlyTheNightBeforeAnyMorning() {
        let evening = testNowMs
        let day = NightWindow.latestCompleted(nowMs: evening, in: chicago)
        #expect(day == LocalDay(year: 2026, month: 10, day: 7))
    }

    /// The stress lookback reads whole local days: from 00:00 of the first lookback day up to the scored
    /// day's 00:00. Minutes before or on the scored day are not read.
    @Test func stressLookbackLoadsWholeLookbackDays() async throws {
        let database = try seededDatabase()
        let day = LocalDay(year: 2026, month: 10, day: 8)
        let first = LocalTime.adding(days: -14, to: day)
        func at(_ d: LocalDay, _ hour: Int) -> Int64 { LocalTime.localTime(d, hour: hour, in: chicago) }
        let included = [at(first, 0), at(LocalTime.adding(days: -1, to: day), 23)]
        let excluded = [at(day, 0), at(LocalTime.adding(days: -15, to: day), 12)]
        try await database.writer.write { db in
            for minute in included + excluded {
                _ = try db.upsertMinuteMetrics(calculatedMinutes(from: minute, count: 1, bpm: 60), computedAtMs: 1)
            }
        }
        let starts = try await database.writer.read { db in
            try db.stressLookback(for: day, in: chicago).windows.map(\.startMs)
        }
        #expect(starts.contains(included[0]))
        #expect(starts.contains(included[1]))
        #expect(!starts.contains(excluded[0]))
        #expect(!starts.contains(excluded[1]))
    }

    /// Rows written by an older stress algorithm are rebuilt once. The rebuild stamps the current version,
    /// and a second pass finds nothing stale (PLAN.md 8.5).
    @Test func staleAlgorithmRowsAreRecomputedOnce() async throws {
        let database = try seededDatabase()
        let end = testNowMs - 60 * LocalTime.msPerMinute
        let start = end - 5 * LocalTime.msPerMinute
        try storeOneMinuteSamples(into: database, endingAt: end, minutes: 5, bpm: 60)
        let worker = MetricsWorker(database: database)
        _ = try await worker.recomputeBackfill(fromMs: start, toMs: end - 1, nowMs: testNowMs)

        // Simulate rows stored by stress algorithm 1.
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE minute_metric SET algo_version = 1")
        }
        let current = AlgoVersion.current.storedValue
        let stale = try await database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM minute_metric WHERE algo_version < ?", arguments: [current])
        }
        #expect(stale == 5)

        let first = try await worker.recomputeStaleRows(nowMs: testNowMs)
        #expect(first.ran)
        #expect(first.changedRows >= 5)
        let staleAfter = try await database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM minute_metric WHERE algo_version < ?", arguments: [current])
        }
        #expect(staleAfter == 0)
        let versions = try await database.writer.read { db in
            try Int.fetchAll(db, sql: "SELECT DISTINCT algo_version FROM minute_metric WHERE minute_ms >= ? AND minute_ms < ?", arguments: [start, end])
        }
        #expect(versions == [current])

        let second = try await worker.recomputeStaleRows(nowMs: testNowMs)
        #expect(second == MetricsWorker.Result(changedRows: 0, ran: false))
    }
}
