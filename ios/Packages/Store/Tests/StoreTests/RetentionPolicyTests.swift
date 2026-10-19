import Foundation
import GRDB
import Metrics
import Testing
@testable import Store

/// The user-configurable retention windows (PLAN.md 10.2 "All windows configurable in
/// Settings → Storage"). Every test gets its own UserDefaults suite, so the runs stay hermetic
/// even though Swift Testing runs them in parallel.
struct RetentionPolicyTests {
    private let day: Int64 = 86_400_000
    private let now: Int64 = 1_800_000_000_000
    private let suiteName = "retention-policy-tests-\(UUID().uuidString)"

    private var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName)!
    }

    private func insertHeartRate(_ timestamps: [Int64], into database: AppDatabase) throws {
        let readings = timestamps.map { ts in
            Database.Reading(peripheralUUID: testPeripheral, tsMs: ts, bpm: 60, contact: nil, rr: [])
        }
        _ = try database.writer.write { try $0.insertReadings(readings) }
    }

    @Test func defaultsMatchTheShippedConstants() {
        #expect(RetentionPolicy.rawDaysDefault == 30)
        #expect(RetentionPolicy.minuteDaysDefault == 400)
        #expect(RetentionPolicy.rawFrameHours == 72)
        #expect(RetentionPolicy.rawDays(in: defaults) == 30)
        #expect(RetentionPolicy.minuteDays(in: defaults) == 400)
        // The bounds contain the defaults, so today's behavior is always a legal configuration.
        #expect(RetentionPolicy.rawDaysBounds.contains(RetentionPolicy.rawDaysDefault))
        #expect(RetentionPolicy.minuteDaysBounds.contains(RetentionPolicy.minuteDaysDefault))
    }

    @Test func changedValuesArePickedUpOnTheNextPurge() throws {
        let database = try AppDatabase.inMemory()
        try insertHeartRate([now - 40 * day, now - 20 * day, now - day], into: database)
        _ = try database.writer.write { db in
            let lastRowid = try Int64.fetchOne(db, sql: "SELECT MAX(rowid) FROM hr_sample") ?? 0
            try db.advanceSyncCursor(.hrSample, to: lastRowid, succeededAtMs: now)
        }

        RetentionPolicy.setRawDays(30, in: defaults)
        let first = try database.writer.write { try $0.purgeExpired(nowMs: now, defaults: defaults) }
        #expect(first.heartRateRows == 1)
        let afterFirst = try database.writer.read {
            try Int64.fetchAll($0, sql: "SELECT ts_ms FROM hr_sample ORDER BY ts_ms")
        }
        #expect(afterFirst == [now - 20 * day, now - day])

        RetentionPolicy.setRawDays(10, in: defaults)
        let second = try database.writer.write { try $0.purgeExpired(nowMs: now, defaults: defaults) }
        #expect(second.heartRateRows == 1)
        let afterSecond = try database.writer.read {
            try Int64.fetchAll($0, sql: "SELECT ts_ms FROM hr_sample ORDER BY ts_ms")
        }
        #expect(afterSecond == [now - day])
    }

    @Test func configuredMinuteWindowDrivesTheMinutePurge() throws {
        let database = try AppDatabase.inMemory()
        _ = try database.writer.write { db in
            try minuteRow(now - 500 * day, syncRev: 1).insert(db)
            try minuteRow(now - 800 * day, syncRev: 2).insert(db)
        }
        // Stored through the raw key on purpose, so the clamp path is exercised end to end.
        RetentionPolicy.setMinuteDays(5_000, in: defaults)
        #expect(RetentionPolicy.minuteDays(in: defaults) == RetentionPolicy.minuteDaysBounds.upperBound)
        let result = try database.writer.write { try $0.purgeExpired(nowMs: now, defaults: defaults) }
        #expect(result.minuteRows == 1)
        let remaining = try database.writer.read {
            try Int64.fetchAll($0, sql: "SELECT minute_ms FROM minute_metric ORDER BY minute_ms")
        }
        #expect(remaining == [now - 500 * day])
    }

    @Test func outOfRangeStoredValuesClampToTheBounds() {
        RetentionPolicy.setRawDays(0, in: defaults)
        #expect(RetentionPolicy.rawDays(in: defaults) == RetentionPolicy.rawDaysBounds.lowerBound)
        RetentionPolicy.setRawDays(1_000, in: defaults)
        #expect(RetentionPolicy.rawDays(in: defaults) == RetentionPolicy.rawDaysBounds.upperBound)
        RetentionPolicy.setMinuteDays(0, in: defaults)
        #expect(RetentionPolicy.minuteDays(in: defaults) == RetentionPolicy.minuteDaysBounds.lowerBound)
        RetentionPolicy.setMinuteDays(10_000, in: defaults)
        #expect(RetentionPolicy.minuteDays(in: defaults) == RetentionPolicy.minuteDaysBounds.upperBound)

        // Values written behind RetentionPolicy's back clamp on read too.
        defaults.set(-5, forKey: RetentionPolicy.rawDaysKey)
        #expect(RetentionPolicy.rawDays(in: defaults) == RetentionPolicy.rawDaysBounds.lowerBound)
        defaults.set(4_000, forKey: RetentionPolicy.minuteDaysKey)
        #expect(RetentionPolicy.minuteDays(in: defaults) == RetentionPolicy.minuteDaysBounds.upperBound)
    }
}

/// Force recompute for a whole-day window (Debug → force recompute).
struct MetricsWorkerBackfillTests {
    @Test func recomputesTheWholeLocalDay() async throws {
        let database = try seededDatabase()
        try storeSamples(into: database, endingAt: testNowMs, minutes: 30, bpm: 60)
        let worker = MetricsWorker(database: database)

        let result = try await worker.recomputeBackfill(days: 1, nowMs: testNowMs)
        #expect(result.ran)
        // Every closed minute of today (midnight Chicago to 14:30 UTC) plus the overlap minute
        // before midnight gets a row, whether or not it had samples.
        let rows = try await database.writer.read {
            try $0.minuteMetricRows(from: testNowMs - 24 * 3_600_000, to: testNowMs)
        }
        #expect(rows.count == 571)
        let sampled = rows.filter { $0.minuteMs >= testNowMs - 30 * LocalTime.msPerMinute }
        #expect(sampled.count == 30)
        #expect(sampled.allSatisfy { $0.hrAvg == 60 && $0.hrN == 60 })

        // A second backfill with unchanged inputs changes nothing.
        let second = try await worker.recomputeBackfill(days: 1, nowMs: testNowMs)
        #expect(second.ran)
        #expect(second.changedRows == 0)
    }

    @Test func backfillCoversPreviousDaysToo() async throws {
        let database = try seededDatabase()
        try storeSamples(into: database, endingAt: testNowMs, minutes: 30, bpm: 60)
        let worker = MetricsWorker(database: database)

        let result = try await worker.recomputeBackfill(days: 3, nowMs: testNowMs)
        #expect(result.ran)
        let rows = try await database.writer.read {
            try $0.minuteMetricRows(from: testNowMs - 3 * 24 * 3_600_000, to: testNowMs)
        }
        // Three days of minute rows, including yesterday's, even where no samples exist. Each day
        // chunk also recomputes the minute before its midnight, which the neighbouring chunk covers.
        let dayStart = LocalTime.localTime(
            LocalTime.localDay(containing: testNowMs, in: chicago),
            hour: 0,
            in: chicago
        )
        #expect(rows.count == 571 + 2 * 1_440)
        let beforeToday = try await database.writer.read {
            try Int64.fetchOne(
                $0,
                sql: "SELECT COUNT(*) FROM minute_metric WHERE minute_ms < ?",
                arguments: [dayStart]
            )
        }
        // Today's chunk reaches one minute before midnight, so yesterday's last minute is here too.
        let beforeTodayInt = Int(beforeToday ?? -1)
        #expect(beforeTodayInt == 2 * 1_440 + 1, "minutes before today's midnight: \(beforeTodayInt)")
    }

    @Test func doesNothingWithoutACompleteProfile() async throws {
        let database = try AppDatabase.inMemory()
        let worker = MetricsWorker(database: database)
        let result = try await worker.recomputeBackfill(days: 7, nowMs: testNowMs)
        #expect(result == MetricsWorker.Result(changedRows: 0, ran: false))
    }

    private func storeSamples(into database: AppDatabase, endingAt nowMs: Int64, minutes: Int, bpm: Int) throws {
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
}
