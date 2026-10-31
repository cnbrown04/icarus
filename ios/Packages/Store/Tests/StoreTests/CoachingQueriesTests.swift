import Foundation
import GRDB
import Metrics
import Testing
@testable import Store

// Coaching inputs read from stored data. testNowMs is 2026-10-07 09:30 in Chicago (a Wednesday).
@Suite("Coaching queries: wake plan, tonight's need, staged timing, weekly days")
struct CoachingQueriesTests {
    private let today = LocalDay(year: 2026, month: 10, day: 7)

    private func localMs(_ day: LocalDay, _ hour: Int, _ minute: Int = 0) -> Int64 {
        LocalTime.localTime(day, hour: hour, in: chicago) + Int64(minute) * LocalTime.msPerMinute
    }

    private func bandID(_ database: AppDatabase) throws -> String {
        try #require(database.writer.read { db in try String.fetchOne(db, sql: "SELECT id FROM band") })
    }

    private func alarm(_ id: String, time: String, weekdays: String, enabled: Bool = true, label: String = "Wake up") -> AlarmRow {
        AlarmRow(
            id: id,
            label: label,
            schedule: #"{"time":"\#(time)","weekdays":\#(weekdays)}"#,
            rhythm: #""double""#,
            channels: #"["phone"]"#,
            enabled: enabled
        )
    }

    /// A main night that ended at `wakeHour`:00 on `wakeDay`, 8 h long, with the given wake minute.
    private func insertNight(endingOn wakeDay: LocalDay, wakeHour: Int = 7, wakeMinute: Int = 0,
                             into database: AppDatabase) throws {
        let end = localMs(wakeDay, wakeHour, wakeMinute)
        let start = end - 8 * 3_600_000
        let band = try bandID(database)
        try database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO sleep_session (band_id, start_ms, end_ms, duration_s, contact_fraction, quality,
                  record_count, is_nap, algo_version, computed_at)
                VALUES (?, ?, ?, ?, 1, 'good', 100, 0, ?, ?)
                """, arguments: [band, start, end, (end - start) / 1000, SleepDeriver.algoVersion, testNowMs])
        }
    }

    // MARK: - Wake plan

    @Test func theNextEnabledAlarmIsTheWakePlan() throws {
        let database = try seededDatabase()
        try database.writer.write { db in
            try db.saveAlarmEdit(alarm("a1", time: "06:30", weekdays: "[]"), nowMs: testNowMs)
        }
        let plan = try database.writer.read { try $0.plannedWake(nowMs: testNowMs, in: chicago) }
        // 06:30 on Thursday Oct 8, the next occurrence after 09:30 on Wednesday.
        #expect(plan?.wakeSec == localMs(LocalDay(year: 2026, month: 10, day: 8), 6, 30) / 1000)
        #expect(plan?.source == .alarm(label: "Wake up"))
    }

    @Test func aDisabledAlarmIsIgnored() throws {
        let database = try seededDatabase()
        try database.writer.write { db in
            try db.saveAlarmEdit(alarm("a1", time: "06:30", weekdays: "[]", enabled: false), nowMs: testNowMs)
        }
        #expect(try database.writer.read { try $0.plannedWake(nowMs: testNowMs, in: chicago) } == nil)
    }

    @Test func anAlarmMoreThanADayAwayIsNotUsed() throws {
        let database = try seededDatabase()
        // Monday only. The next Monday is Oct 12, more than 24 h away, and there is no sleep to fall back on.
        try database.writer.write { db in
            try db.saveAlarmEdit(alarm("a1", time: "06:30", weekdays: "[1]"), nowMs: testNowMs)
        }
        #expect(try database.writer.read { try $0.plannedWake(nowMs: testNowMs, in: chicago) } == nil)
    }

    @Test func withNoAlarmTheMedianOfRecentWakesIsUsed() throws {
        let database = try seededDatabase()
        for offset in 1...7 {
            try insertNight(endingOn: LocalTime.adding(days: -offset, to: today), wakeHour: 7, wakeMinute: 10,
                            into: database)
        }
        let plan = try database.writer.read { try $0.plannedWake(nowMs: testNowMs, in: chicago) }
        #expect(plan?.wakeSec == localMs(LocalDay(year: 2026, month: 10, day: 8), 7, 10) / 1000)
        #expect(plan?.source == .medianOfRecentWakes(nights: 7))
    }

    // MARK: - Tonight's need and timing

    @Test func withNoDataTheInputsAreTheDefaults() throws {
        let database = try seededDatabase()
        let inputs = try database.writer.read { try $0.coachingInputs(nowMs: testNowMs, in: chicago) }
        #expect(inputs.day == today)
        #expect(inputs.todayStrain == nil)
        #expect(inputs.recoveryPercent == nil)
        #expect(inputs.carriedDebtSec == 0)
        #expect(inputs.tonightNeedSec == SleepNeed.defaultBaselineSec)
        #expect(inputs.timing.isDefault)
        #expect(inputs.wake == nil)
    }

    @Test func aStagedNightGivesLatencyAndEfficiency() throws {
        let database = try seededDatabase()
        let wakeDay = LocalTime.adding(days: -1, to: today)
        let start = localMs(LocalTime.adding(days: -1, to: wakeDay), 23) / 1000
        let band = try bandID(database)
        let end = start + 8 * 3_600
        // Wake 10 min, light 60 min, deep 60 min, REM 30 min, wake 10 min. Staged total 170 min, asleep 150 min.
        let segments: [(String, Int64, Int64)] = [
            ("wake", start, start + 600),
            ("light", start + 600, start + 600 + 3_600),
            ("deep", start + 4_200, start + 4_200 + 3_600),
            ("rem", start + 7_800, start + 7_800 + 1_800),
            ("wake", start + 9_600, start + 10_200),
        ]
        try database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO sleep_session (band_id, start_ms, end_ms, duration_s, contact_fraction, quality,
                  record_count, is_nap, algo_version, computed_at)
                VALUES (?, ?, ?, ?, 1, 'good', 100, 0, ?, ?)
                """, arguments: [band, start * 1000, end * 1000, 8 * 3_600, SleepDeriver.algoVersion, testNowMs])
            for (stage, from, to) in segments {
                try db.execute(sql: """
                    INSERT INTO sleep_stage_segment (band_id, session_start_ms, start_ms, end_ms, stage,
                      algo_version, computed_at) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [band, start * 1000, from * 1000, to * 1000, stage, SleepStager.algoVersion, testNowMs])
            }
        }
        let inputs = try database.writer.read { try $0.coachingInputs(nowMs: testNowMs, in: chicago) }
        #expect(!inputs.timing.isDefault)
        #expect(inputs.timing.latencySec == 600)
        #expect(abs(inputs.timing.efficiency - 150.0 / 170.0) < 1e-9)
    }

    @Test func aNightWithDebtRaisesTonightsNeed() throws {
        let database = try seededDatabase()
        // Last night was 8 h, so there is no debt. Add a 5 h night before it to make some.
        try insertNight(endingOn: LocalTime.adding(days: -1, to: today), into: database)
        let shortStart = localMs(LocalTime.adding(days: -2, to: today), 2)
        let band = try bandID(database)
        try database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO sleep_session (band_id, start_ms, end_ms, duration_s, contact_fraction, quality,
                  record_count, is_nap, algo_version, computed_at)
                VALUES (?, ?, ?, ?, 1, 'poor', 100, 0, ?, ?)
                """, arguments: [band, shortStart, shortStart + 5 * 3_600_000, 5 * 3_600,
                                 SleepDeriver.algoVersion, testNowMs])
        }
        let inputs = try database.writer.read { try $0.coachingInputs(nowMs: testNowMs, in: chicago) }
        #expect(inputs.carriedDebtSec > 0)
        #expect(inputs.tonightNeedSec > SleepNeed.defaultBaselineSec)
        #expect(inputs.tonightNeedSec <= SleepNeed.maxNeedSec)
    }

    // MARK: - Weekly days

    @Test func weeklyDaysRunToYesterdayAndAreOldestFirst() throws {
        let database = try seededDatabase()
        let days = try database.writer.read { try $0.weeklyDays(nowMs: testNowMs, in: chicago) }
        #expect(days.thisWeek.count == 7)
        #expect(days.previousWeek.count == 7)
        #expect(days.thisWeek.allSatisfy { $0.hoursSlept == nil && $0.recovery == nil })
    }

    @Test func aNightYesterdayLandsInTheLastSlotOfThisWeek() throws {
        let database = try seededDatabase()
        try insertNight(endingOn: LocalTime.adding(days: -1, to: today), into: database)
        let days = try database.writer.read { try $0.weeklyDays(nowMs: testNowMs, in: chicago) }
        let yesterday = try #require(days.thisWeek.last)
        let hours = try #require(yesterday.hoursSlept)
        #expect(abs(hours - 8) < 0.01)
        // A single 8 h night against an 8 h baseline is 100 % sleep performance.
        #expect(yesterday.sleepPerformance == 100)
        #expect(days.thisWeek.dropLast().allSatisfy { $0.hoursSlept == nil })
    }

    /// Weekly HRV and resting HR are the main sleep's values, the same numbers Recovery and Vitals show.
    @Test func weeklyHeartValuesComeFromTheMainSleep() throws {
        let database = try seededDatabase()
        let yesterday = LocalTime.adding(days: -1, to: today)
        try insertNight(endingOn: yesterday, into: database)
        try database.writer.write { db in
            try db.execute(sql: "UPDATE sleep_session SET rmssd_ms = 42, resting_hr = 61")
        }
        let days = try database.writer.read { try $0.weeklyDays(nowMs: testNowMs, in: chicago) }
        let last = try #require(days.thisWeek.last)
        #expect(last.hrv == 42)
        #expect(last.restingHR == 61)
    }
}
