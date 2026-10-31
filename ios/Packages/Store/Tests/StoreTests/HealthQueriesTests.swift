import Foundation
import GRDB
import Metrics
import Testing
@testable import Store

// Health reads: the per-day score series and the nightly vitals against the 30-night range.
// The profile (seededDatabase) is male, born 1990, so HRmax is Tanaka for 2026.
@Suite("Health queries")
struct HealthQueriesTests {
    private let day = LocalDay(year: 2026, month: 10, day: 20)

    private func localMs(_ day: LocalDay, _ hour: Int, _ minute: Int = 0) -> Int64 {
        LocalTime.localTime(day, hour: hour, in: chicago) + Int64(minute) * LocalTime.msPerMinute
    }

    private func bandID(_ database: AppDatabase) throws -> String {
        try #require(database.writer.read { db in try String.fetchOne(db, sql: "SELECT id FROM band") })
    }

    /// The main sleep that ended on `wakeDay` at 07:00, with the given nightly values. When `skinTemp` is set,
    /// one historical record inside the sleep carries that raw skin-temperature byte.
    private func insertNight(
        endingOn wakeDay: LocalDay,
        rmssd: Double? = 60,
        restingHR: Double? = 55,
        respRate: Double? = 15,
        skinTemp: [Int] = [],
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
            for (index, value) in skinTemp.enumerated() {
                try db.execute(sql: """
                    INSERT INTO historical_record (band_id, ts_ms, version, skin_temp_raw)
                    VALUES (?, ?, 24, ?)
                    """, arguments: [band, start + Int64(index + 1) * 60_000, value])
            }
        }
    }

    // MARK: Vitals

    @Test func vitalsJudgeTonightAgainstPriorNightsOnly() throws {
        let database = try seededDatabase()
        for offset in 1...10 {
            try insertNight(endingOn: LocalTime.adding(days: -offset, to: day), skinTemp: [100], into: database)
        }
        // Tonight is far off on resting HR, so if it leaked into its own range the median would move.
        try insertNight(endingOn: day, rmssd: 40, restingHR: 62, respRate: 15, skinTemp: [103], into: database)

        let vitals = try database.writer.read { try $0.vitalsBaseline(day: day, in: chicago) }
        #expect(vitals.baselines[.restingHR]?.nights == 10)
        #expect(vitals.baselines[.restingHR]?.center == 55)
        #expect(vitals.tonight[.hrv] == 40)

        let statuses = Dictionary(uniqueKeysWithValues: vitals.statuses.map { ($0.vital, $0) })
        #expect(statuses[.restingHR]?.state == .above)
        #expect(statuses[.hrv]?.state == .below)
        #expect(statuses[.respiratoryRate]?.state == .inRange)
        #expect(HealthMonitor.summary(vitals.statuses) == HealthMonitor.Summary(inRange: 1, evaluated: 3))
    }

    @Test func fewPriorNightsLeaveEveryVitalCalibrating() throws {
        let database = try seededDatabase()
        for offset in 1...3 {
            try insertNight(endingOn: LocalTime.adding(days: -offset, to: day), into: database)
        }
        try insertNight(endingOn: day, into: database)

        let vitals = try database.writer.read { try $0.vitalsBaseline(day: day, in: chicago) }
        #expect(vitals.baselines.isEmpty)
        #expect(vitals.statuses.allSatisfy { $0.state == .calibrating })
        #expect(HealthMonitor.summary(vitals.statuses).evaluated == 0)
    }

    /// A vital missing on some nights calibrates on its own count, not on the number of nights slept.
    @Test func eachVitalCountsOnlyTheNightsThatCarryIt() throws {
        let database = try seededDatabase()
        for offset in 1...7 {
            try insertNight(endingOn: LocalTime.adding(days: -offset, to: day), rmssd: offset <= 3 ? 50 : nil,
                            into: database)
        }
        let vitals = try database.writer.read { try $0.vitalsBaseline(day: day, in: chicago) }
        #expect(vitals.priorNights == 7)
        #expect(vitals.nightsWithValue[.restingHR] == 7)
        #expect(vitals.nightsWithValue[.hrv] == 3)
        #expect(vitals.baselines[.hrv] == nil)
    }

    // MARK: Score series

    @Test func seriesCarriesPerDayValuesAndOneEntryPerDay() throws {
        let database = try seededDatabase()
        let first = LocalDay(year: 2026, month: 10, day: 18)
        try insertNight(endingOn: day, rmssd: 45, restingHR: 57, respRate: 16, into: database)
        // Two stress minutes on the 19th, averaging 40.
        let nineteenth = LocalDay(year: 2026, month: 10, day: 19)
        try insertMinuteRows([
            minuteRow(localMs(nineteenth, 9), stress: 30),
            minuteRow(localMs(nineteenth, 9, 1), stress: 50),
        ], into: database)

        let series = try database.writer.read {
            try $0.dailyScoreSeries(from: first, through: day, in: chicago)
        }
        #expect(series.map(\.day) == [first, nineteenth, day])

        let tonight = try #require(series.last)
        #expect(tonight.hrvMs == 45)
        #expect(tonight.restingHR == 57)
        #expect(tonight.respiratoryRate == 16)
        // Only one prior night exists, so recovery is still calibrating and has no value.
        #expect(tonight.recovery == nil)

        #expect(series[1].stressAverage == 40)
        #expect(series[0].hrvMs == nil)
        #expect(series[0].stressAverage == nil)
    }

    @Test func emptyRangeGivesNoPoints() throws {
        let database = try seededDatabase()
        let series = try database.writer.read {
            try $0.dailyScoreSeries(from: day, through: LocalTime.adding(days: -1, to: day), in: chicago)
        }
        #expect(series.isEmpty)
    }
}
