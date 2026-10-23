import Foundation
import GRDB
import Metrics
import Testing
@testable import Store

// One day's strain, recovery, sleep coaching and regularity, read from stored sessions and minutes.
// The profile (seededDatabase) is male, born 1990, no entered HRmax, so HRmax is Tanaka for 2026.
@Suite("Daily scores")
struct DailyScoresTests {
    private let day = LocalDay(year: 2026, month: 10, day: 20)

    private func localMs(_ day: LocalDay, _ hour: Int, _ minute: Int = 0) -> Int64 {
        LocalTime.localTime(day, hour: hour, in: chicago) + Int64(minute) * LocalTime.msPerMinute
    }

    private func bandID(_ database: AppDatabase) throws -> String {
        try #require(database.writer.read { db in try String.fetchOne(db, sql: "SELECT id FROM band") })
    }

    /// The main sleep that ended on `wakeDay` at 07:00 (23:00 the evening before), with the given
    /// nightly values written straight into the row.
    private func insertNight(
        endingOn wakeDay: LocalDay,
        rmssd: Double = 50,
        restingHR: Double = 55,
        respRate: Double? = 15,
        isNap: Bool = false,
        into database: AppDatabase
    ) throws {
        let start = localMs(LocalTime.adding(days: -1, to: wakeDay), 23)
        let end = localMs(wakeDay, 7)
        let band = try bandID(database)
        try database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO sleep_session (band_id, start_ms, end_ms, duration_s, resting_hr, rmssd_ms,
                  resp_rate_brpm, contact_fraction, quality, record_count, is_nap, algo_version, computed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, 1, 'good', 100, ?, ?, ?)
                """, arguments: [band, start, end, (end - start) / 1000, restingHR, rmssd, respRate,
                                 isNap ? 1 : 0, SleepDeriver.algoVersion, testNowMs])
        }
    }

    private func scores(_ database: AppDatabase, _ day: LocalDay) throws -> DailyScores {
        try database.writer.read { try $0.dailyScores(day: day, in: chicago) }
    }

    // MARK: Recovery

    @Test func recoveryCalibratesUntilFourBaselineNights() throws {
        let database = try seededDatabase()
        for offset in 1...3 {
            try insertNight(endingOn: LocalTime.adding(days: -offset, to: day), into: database)
        }
        try insertNight(endingOn: day, into: database)
        guard case let .insufficientBaseline(_, validNights) = try #require(scores(database, day).recovery) else {
            Issue.record("three baseline nights must not score")
            return
        }
        #expect(validNights == 3)
    }

    @Test func recoveryScoresAgainstEarlierNightsOnly() throws {
        let database = try seededDatabase()
        for offset in 1...10 {
            try insertNight(endingOn: LocalTime.adding(days: -offset, to: day), rmssd: 50 + Double(offset % 3), into: database)
        }
        // A strong night: HRV well above the ~50 ms baseline.
        try insertNight(endingOn: day, rmssd: 80, into: database)
        guard case let .scored(score) = try #require(scores(database, day).recovery) else {
            Issue.record("ten baseline nights must score")
            return
        }
        #expect(score.score > 67)
        #expect(score.hrvBaseline.nValid == 10)
    }

    @Test func nightsOutsideTheSixtyDayWindowAreNotBaseline() throws {
        let database = try seededDatabase()
        // Four nights four months back (the real store had June nights) and none recently.
        for offset in 120...123 {
            try insertNight(endingOn: LocalTime.adding(days: -offset, to: day), into: database)
        }
        try insertNight(endingOn: day, into: database)
        guard case let .insufficientBaseline(_, validNights) = try #require(scores(database, day).recovery) else {
            Issue.record("months-old nights must not seed a baseline")
            return
        }
        #expect(validNights == 0)
    }

    @Test func noMainSleepMeansNoRecoveryOrSleepScore() throws {
        let database = try seededDatabase()
        try insertNight(endingOn: LocalTime.adding(days: -1, to: day), into: database)
        try insertNight(endingOn: day, isNap: true, into: database)
        let result = try scores(database, day)
        #expect(result.recovery == nil)
        // Yesterday's night must not stand in for today's performance.
        #expect(result.sleep == nil)
        #expect(result.respiratoryRateBrpm == nil)
    }

    // MARK: Sleep

    @Test func sleepCoachingAndRespiratoryRateComeFromTheNightThatEndedToday() throws {
        let database = try seededDatabase()
        try insertNight(endingOn: LocalTime.adding(days: -1, to: day), into: database)
        try insertNight(endingOn: day, respRate: 14.5, into: database)
        let result = try scores(database, day)
        let sleep = try #require(result.sleep)
        // Unstaged rows count the 8 h in-bed span as asleep; need is the 8 h default plus carried debt.
        #expect(sleep.asleepSec == 8 * 3600)
        #expect(sleep.performancePct == 100)
        #expect(result.respiratoryRateBrpm == 14.5)
        // Two identical nights: perfectly regular.
        #expect(result.sleepRegularityIndex == 100)
    }

    // MARK: Strain

    @Test func strainScoresAnActiveDayAndBorrowsTheLatestRestingHR() throws {
        let database = try seededDatabase()
        // The night before `day` has no session, so resting HR comes from the latest main sleep.
        try insertNight(endingOn: LocalTime.adding(days: -2, to: day), restingHR: 55, into: database)
        var rows: [MinuteMetricRow] = []
        for minute in 0..<(12 * 60) {
            // Mostly 90 bpm walking-around minutes, with an hour at 150.
            let hr: Double = minute < 60 ? 150 : 90
            rows.append(minuteRow(localMs(day, 8) + Int64(minute) * LocalTime.msPerMinute, hr: hr))
        }
        try insertMinuteRows(rows, into: database)

        let strain = try #require(scores(database, day).strain)
        #expect(strain.effort > 0)
        #expect(strain.whoopScale > 0)
        #expect(strain.whoopScale <= 21)
    }

    @Test func aRestingDayScoresLessThanAnActiveOne() throws {
        let database = try seededDatabase()
        try insertNight(endingOn: day, restingHR: 55, into: database)
        let next = LocalTime.adding(days: 1, to: day)
        var rows: [MinuteMetricRow] = []
        for minute in 0..<(12 * 60) {
            rows.append(minuteRow(localMs(day, 8) + Int64(minute) * LocalTime.msPerMinute, hr: 70))
            rows.append(minuteRow(localMs(next, 8) + Int64(minute) * LocalTime.msPerMinute, hr: minute < 120 ? 150 : 95))
        }
        try insertMinuteRows(rows, into: database)
        let resting = try #require(scores(database, day).strain)
        let active = try #require(scores(database, next).strain)
        #expect(active.effort > resting.effort)
    }

    @Test func noMinutesMeansNoStrain() throws {
        let database = try seededDatabase()
        try insertNight(endingOn: day, into: database)
        #expect(try scores(database, day).strain == nil)
    }
}
