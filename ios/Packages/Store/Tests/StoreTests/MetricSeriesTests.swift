import Foundation
import GRDB
import Metrics
import Testing
@testable import Store

// The metric read path: the daily_score cache against dailyScores, the single sources, the stress and heart-rate
// latest rules, and intraday series. Uses the same profile as DailyScoresTests (male, born 1990, Chicago).
@Suite("Metric series")
struct MetricSeriesTests {
    private let day = LocalDay(year: 2026, month: 10, day: 20)

    private func localMs(_ day: LocalDay, _ hour: Int, _ minute: Int = 0) -> Int64 {
        LocalTime.localTime(day, hour: hour, in: chicago) + Int64(minute) * LocalTime.msPerMinute
    }

    private func bandID(_ database: AppDatabase) throws -> String {
        try #require(database.writer.read { db in try String.fetchOne(db, sql: "SELECT id FROM band") })
    }

    /// The main sleep that ended on `wakeDay` at 07:00, with the nightly values written straight into the row.
    private func insertNight(
        endingOn wakeDay: LocalDay,
        rmssd: Double = 50,
        restingHR: Double = 55,
        respRate: Double? = 15,
        into database: AppDatabase
    ) throws {
        let start = localMs(LocalTime.adding(days: -1, to: wakeDay), 23)
        let end = localMs(wakeDay, 7)
        let band = try bandID(database)
        try database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO sleep_session (band_id, start_ms, end_ms, duration_s, resting_hr, rmssd_ms,
                  resp_rate_brpm, contact_fraction, quality, record_count, is_nap, algo_version, computed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, 1, 'good', 100, 0, ?, ?)
                """, arguments: [band, start, end, (end - start) / 1000, restingHR, rmssd, respRate,
                                 SleepDeriver.algoVersion, testNowMs])
        }
    }

    /// Seeds four prior nights and the wake night for `day`, then refreshes the cache for those days.
    private func seededWithScores() throws -> AppDatabase {
        let database = try seededDatabase()
        for offset in 1...4 {
            try insertNight(endingOn: LocalTime.adding(days: -offset, to: day), rmssd: 40 + Double(offset), restingHR: 52, into: database)
        }
        try insertNight(endingOn: day, rmssd: 60, restingHR: 50, respRate: 14, into: database)
        try database.writer.write { db in
            try db.refreshDailyScores(from: LocalTime.adding(days: -4, to: day), through: day, in: chicago, nowMs: testNowMs)
        }
        return database
    }

    private func minute(_ database: AppDatabase, _ row: MinuteMetricRow) throws {
        try insertMinuteRows([row], into: database)
    }

    // MARK: Cache

    @Test func cacheRowEqualsDailyScoresForTheDay() throws {
        let database = try seededWithScores()
        let scores = try database.writer.read { try $0.dailyScores(day: day, in: chicago) }
        let row = try #require(database.writer.read { db in
            try DailyScoreRow.fetchOne(db, sql: "SELECT * FROM daily_score WHERE local_day = '2026-10-20'")
        })

        guard case let .scored(score)? = scores.recovery else {
            Issue.record("the fixture night must score recovery")
            return
        }
        #expect(row.recovery == score.score)
        #expect(row.recoveryCalibrating == false)
        #expect(row.strain == scores.strain?.whoopScale)
        #expect(row.sleepPerformance == scores.sleep?.performancePct)
        #expect(row.asleepSec == scores.sleep.map { Int64($0.asleepSec.rounded()) })
        #expect(row.restingHR == 50)
        #expect(row.rmssdMs == 60)
        #expect(row.respRate == 14)
        #expect(row.computedAt == testNowMs)
    }

    @Test func cacheRowCalibratesWithoutABaseline() throws {
        let database = try seededDatabase()
        try insertNight(endingOn: day, into: database)
        try database.writer.write { db in
            try db.refreshDailyScores(from: day, through: day, in: chicago, nowMs: testNowMs)
        }
        let row = try #require(database.writer.read { db in
            try DailyScoreRow.fetchOne(db, sql: "SELECT * FROM daily_score WHERE local_day = '2026-10-20'")
        })
        #expect(row.recovery == nil)
        #expect(row.recoveryCalibrating == true)
    }

    @Test func refreshByMillisecondRangeWritesEachDayOnce() async throws {
        let database = try seededDatabase()
        let fromMs = localMs(LocalDay(year: 2026, month: 10, day: 18), 9)
        let toMs = localMs(LocalDay(year: 2026, month: 10, day: 20), 21)
        try await database.refreshDailyScores(fromMs: fromMs, toMs: toMs, nowMs: testNowMs)
        let keys = try await database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT local_day FROM daily_score ORDER BY local_day")
        }
        #expect(keys == ["2026-10-18", "2026-10-19", "2026-10-20"])
    }

    @Test func backfillIsNeededOnlyWhenEmptyOrOlderThanTheAlgorithm() async throws {
        let database = try seededDatabase()
        #expect(try await database.dailyScoresNeedBackfill())
        try await database.refreshDailyScores(lastDays: 3, nowMs: testNowMs)
        #expect(try await database.dailyScoresNeedBackfill())
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE daily_score SET computed_at = ?", arguments: [DailyScoreCache.algoSinceMs])
        }
        #expect(try await database.dailyScoresNeedBackfill() == false)
    }

    // MARK: Single sources

    @Test func coachingNeedAndDebtMatchTheCacheForToday() throws {
        let database = try seededWithScores()
        let nowMs = localMs(day, 12)
        try database.writer.write { db in
            try db.refreshDailyScores(from: day, through: day, in: chicago, nowMs: nowMs)
        }
        let inputs = try database.writer.read { try $0.coachingInputs(nowMs: nowMs, in: chicago) }
        let row = try #require(database.writer.read { db in
            try DailyScoreRow.fetchOne(db, sql: "SELECT * FROM daily_score WHERE local_day = '2026-10-20'")
        })
        #expect(row.sleepNeedSec == Int64(inputs.tonightNeedSec.rounded()))
        #expect(row.sleepDebtSec == Int64(inputs.carriedDebtSec.rounded()))
    }

    @Test func restingHRIsTheSameNumberOnSummaryAndInItsDay() throws {
        let database = try seededWithScores()
        let nowMs = localMs(day, 12)
        let latest = try database.writer.read { try $0.metricLatest(.restingHR, nowMs: nowMs, in: chicago) }
        let days = try database.writer.read {
            try $0.metricDays(.restingHR, from: day, through: day, in: chicago)
        }
        let sessionEnd = localMs(day, 7)
        #expect(latest.value == 50)
        #expect(latest.atMs == sessionEnd)
        #expect(days == [MetricDayValue(day: day, value: 50)])
        #expect(latest.value == days.first?.value)
    }

    @Test func hrvAndRespiratoryRateReadTheMainSleepSession() throws {
        let database = try seededWithScores()
        let nowMs = localMs(day, 12)
        let hrv = try database.writer.read { try $0.metricLatest(.hrv, nowMs: nowMs, in: chicago) }
        let resp = try database.writer.read { try $0.metricLatest(.respiratoryRate, nowMs: nowMs, in: chicago) }
        #expect(hrv.value == 60)
        #expect(resp.value == 14)
    }

    @Test func dailyKindsReadTodaysCacheRowAndRebuildItWhenStale() throws {
        let database = try seededWithScores()
        let nowMs = localMs(day, 12)
        let recovery = try database.writer.read { try $0.metricLatest(.recovery, nowMs: nowMs, in: chicago) }
        let scores = try database.writer.read { try $0.dailyScores(day: day, in: chicago) }
        guard case let .scored(score)? = scores.recovery else {
            Issue.record("the fixture night must score recovery")
            return
        }
        #expect(recovery.value == score.score)
        #expect(recovery.state == nil)
        // A stale row is rebuilt for the read: its computed_at moves to the read's clock. A read-only call still
        // returns the fresh value, but cannot store it.
        let later = nowMs + 10 * LocalTime.msPerMinute
        let fromRead = try database.writer.read { try $0.metricLatest(.strain, nowMs: later, in: chicago) }
        let fromWrite = try database.writer.write { try $0.metricLatest(.strain, nowMs: later, in: chicago) }
        #expect(fromRead == fromWrite)
        let computedAt = try database.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT computed_at FROM daily_score WHERE local_day = '2026-10-20'")
        }
        #expect(computedAt == later)
    }

    // MARK: Stress and heart rate

    @Test func stressIsTheLatestScoredMinuteWithinTenMinutes() throws {
        let database = try seededDatabase()
        let now = localMs(day, 12)
        try minute(database, minuteRow(now - 20 * LocalTime.msPerMinute, stress: 30))
        try minute(database, minuteRow(now - 5 * LocalTime.msPerMinute, stress: 72))
        let reading = try database.writer.read { try $0.metricLatest(.stress, nowMs: now, in: chicago) }
        #expect(reading.value == 72)
        #expect(reading.atMs == now - 5 * LocalTime.msPerMinute)
        #expect(reading.state == "value")
    }

    /// Heart-rate-only minutes carry a stress score too (most of the day on this band): they are the latest reading
    /// and they are on the intraday chart. On 2026-10-31 Summary read "Not enough data" over a run of hr_only scores.
    @Test func heartRateOnlyMinutesAreScoredStress() throws {
        let database = try seededDatabase()
        let now = localMs(day, 12)
        var hrOnly = minuteRow(now - 2 * LocalTime.msPerMinute, stress: 13)
        hrOnly.stressState = StressState.hrOnly.rawValue
        try minute(database, hrOnly)
        let reading = try database.writer.read { try $0.metricLatest(.stress, nowMs: now, in: chicago) }
        #expect(reading.value == 13)
        #expect(reading.state == "hr_only")
        let points = try database.writer.read { try $0.metricIntraday(.stress, day: day, in: chicago) }
        #expect(points.map(\.value) == [13])
    }

    @Test func stressFallsBackToTheLatestMinuteState() throws {
        let database = try seededDatabase()
        let now = localMs(day, 12)
        try minute(database, minuteRow(now - 40 * LocalTime.msPerMinute, stress: 30))
        var calibrating = minuteRow(now - 2 * LocalTime.msPerMinute, stress: nil)
        calibrating.stressState = StressState.calibrating.rawValue
        try minute(database, calibrating)
        let reading = try database.writer.read { try $0.metricLatest(.stress, nowMs: now, in: chicago) }
        #expect(reading.value == nil)
        #expect(reading.state == "calibrating")
        #expect(reading.atMs == now - 2 * LocalTime.msPerMinute)
    }

    @Test func staleScoredStressIsWordedStale() throws {
        let database = try seededDatabase()
        let now = localMs(day, 12)
        try minute(database, minuteRow(now - 30 * LocalTime.msPerMinute, stress: 30))
        let reading = try database.writer.read { try $0.metricLatest(.stress, nowMs: now, in: chicago) }
        #expect(reading.value == nil)
        #expect(reading.state == "stale")
    }

    @Test func heartRateIsTheLatestMinuteWithinTenMinutes() throws {
        let database = try seededDatabase()
        let now = localMs(day, 12)
        try minute(database, minuteRow(now - 3 * LocalTime.msPerMinute, hr: 74))
        let recent = try database.writer.read { try $0.metricLatest(.heartRate, nowMs: now, in: chicago) }
        #expect(recent.value == 74)
        let late = now + 30 * LocalTime.msPerMinute
        let old = try database.writer.read { try $0.metricLatest(.heartRate, nowMs: late, in: chicago) }
        #expect(old.value == nil)
    }

    // MARK: Intraday and day series

    @Test func intradayHeartRateIsEachMinutesAverage() throws {
        let database = try seededDatabase()
        let start = localMs(day, 9)
        try insertMinuteRows([
            minuteRow(start, hr: 60),
            minuteRow(start + LocalTime.msPerMinute, hr: 66),
        ], into: database)
        let points = try database.writer.read {
            try $0.metricIntraday(.heartRate, day: day, in: chicago)
        }
        #expect(points == [MetricPoint(tsMs: start, value: 60), MetricPoint(tsMs: start + LocalTime.msPerMinute, value: 66)])
    }

    @Test func intradayStressKeepsOnlyScoredMinutes() throws {
        let database = try seededDatabase()
        let start = localMs(day, 9)
        var calibrating = minuteRow(start + LocalTime.msPerMinute, stress: nil)
        calibrating.stressState = StressState.calibrating.rawValue
        try insertMinuteRows([minuteRow(start, stress: 40), calibrating], into: database)
        let points = try database.writer.read { try $0.metricIntraday(.stress, day: day, in: chicago) }
        #expect(points == [MetricPoint(tsMs: start, value: 40)])
    }

    /// A day the band was not worn has minute rows carrying only the resting estimate. It must not chart ~1,600 kcal
    /// for a day nobody measured: without heart rate the day has no calories. A measured day keeps its total.
    @Test func aDayWithoutHeartRateHasNoCalories() throws {
        let database = try seededDatabase()
        let unworn = LocalTime.adding(days: -1, to: day)
        try insertMinuteRows([
            minuteRow(localMs(unworn, 9), hr: nil, kcal: 1.1),
            minuteRow(localMs(day, 9), hr: 70, kcal: 2),
        ], into: database)
        try database.writer.write { db in
            try db.refreshDailyScores(from: unworn, through: day, in: chicago, nowMs: testNowMs)
        }
        let kcal = try database.writer.read { try $0.metricDays(.calories, from: unworn, through: day, in: chicago) }
        #expect(kcal.map(\.value) == [nil, 2])
    }

    @Test func intradayCaloriesSumPerLocalHour() throws {
        let database = try seededDatabase()
        let nineAM = localMs(day, 9)
        try insertMinuteRows([
            minuteRow(nineAM, kcal: 1.5),
            minuteRow(nineAM + LocalTime.msPerMinute, kcal: 2.5),
            minuteRow(localMs(day, 10), kcal: 3),
        ], into: database)
        let points = try database.writer.read { try $0.metricIntraday(.calories, day: day, in: chicago) }
        #expect(points == [
            MetricPoint(tsMs: nineAM, value: 4),
            MetricPoint(tsMs: localMs(day, 10), value: 3),
        ])
    }

    @Test func kindsWithoutIntradayValuesAreEmpty() throws {
        let database = try seededDatabase()
        for kind in MetricKind.allCases where !kind.hasIntraday {
            let points = try database.writer.read { try $0.metricIntraday(kind, day: day, in: chicago) }
            #expect(points.isEmpty, "\(kind)")
        }
    }

    @Test func dayValuesHaveOneEntryPerDayWithNilForMissingRows() throws {
        let database = try seededWithScores()
        let first = LocalTime.adding(days: -6, to: day)
        let values = try database.writer.read {
            try $0.metricDays(.recovery, from: first, through: day, in: chicago)
        }
        #expect(values.count == 7)
        #expect(values.first?.day == first)
        #expect(values.last?.day == day)
        #expect(values.last?.value != nil)
        #expect(values.dropLast().allSatisfy { $0.value == nil })
    }

    /// Minute averages of 60, 66 and 90 bpm (plus one minute with no heart rate) on `day`.
    private func seedHeartRateMinutes(_ database: AppDatabase) throws {
        let nineAM = localMs(day, 9)
        try insertMinuteRows([
            minuteRow(nineAM, hr: 60),
            minuteRow(nineAM + LocalTime.msPerMinute, hr: 66),
            minuteRow(nineAM + 2 * LocalTime.msPerMinute, hr: nil),
            minuteRow(localMs(day, 10), hr: 90),
        ], into: database)
    }

    @Test func heartRateCacheIsTheMeanMinAndMaxOfTheMinuteAverages() throws {
        let database = try seededDatabase()
        try seedHeartRateMinutes(database)
        try database.writer.write { db in
            try db.refreshDailyScores(from: day, through: day, in: chicago, nowMs: testNowMs)
        }
        let row = try #require(database.writer.read { db in
            try DailyScoreRow.fetchOne(db, sql: "SELECT * FROM daily_score WHERE local_day = '2026-10-20'")
        })
        // (60 + 66 + 90) / 3, with the null minute ignored.
        #expect(row.hrAvg == 72)
        #expect(row.hrMin == 60)
        #expect(row.hrMax == 90)
        let values = try database.writer.read {
            try $0.metricDays(.heartRate, from: day, through: day, in: chicago)
        }
        #expect(values == [MetricDayValue(day: day, value: 72)])
    }

    @Test func heartRateRangeListsOnlyDaysWithMinutes() throws {
        let database = try seededDatabase()
        try seedHeartRateMinutes(database)
        let first = LocalTime.adding(days: -2, to: day)
        try database.writer.write { db in
            try db.refreshDailyScores(from: first, through: day, in: chicago, nowMs: testNowMs)
        }
        let ranges = try database.writer.read {
            try $0.heartRateRange(from: first, through: day, in: chicago)
        }
        #expect(ranges == [HeartRateDayRange(day: day, min: 60, max: 90)])
    }
}
