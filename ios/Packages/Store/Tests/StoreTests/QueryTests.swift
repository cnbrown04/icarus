import Foundation
import GRDB
import Metrics
import Testing
@testable import Store

struct QueryTests {
    private let day = LocalDay(year: 2026, month: 10, day: 7)

    private func localMs(_ hour: Int, _ minute: Int = 0) -> Int64 {
        LocalTime.localTime(day, hour: hour, in: chicago) + Int64(minute) * LocalTime.msPerMinute
    }

    @Test func heartRateRowsAreHalfOpenAndOrdered() throws {
        let database = try seededDatabase()
        _ = try database.writer.write { db in
            let band = try String.fetchOne(db, sql: "SELECT id FROM band") ?? ""
            for ts: Int64 in [30, 10, 20, 40] {
                try db.execute(sql: "INSERT INTO hr_sample (band_id, ts_ms, bpm, source) VALUES (?, ?, 60, 1)", arguments: [band, ts])
            }
        }
        let rows = try database.writer.read { try $0.heartRateRows(from: 10, to: 40) }
        #expect(rows.map(\.tsMs) == [10, 20, 30])
    }

    @Test func minuteRangeIsHalfOpen() throws {
        let database = try AppDatabase.inMemory()
        try insertMinuteRows((0..<5).map { minuteRow(Int64($0) * LocalTime.msPerMinute) }, into: database)
        let rows = try database.writer.read { try $0.minuteMetricRows(from: LocalTime.msPerMinute, to: 3 * LocalTime.msPerMinute) }
        #expect(rows.map(\.minuteMs) == [LocalTime.msPerMinute, 2 * LocalTime.msPerMinute])
    }

    @Test func latestMinuteWithHeartRateSkipsEstimatedMinutes() throws {
        let database = try AppDatabase.inMemory()
        try insertMinuteRows([
            minuteRow(0, hr: 61),
            minuteRow(60_000, hr: nil),
            minuteRow(120_000, hr: 64),
            minuteRow(180_000, hr: nil),
        ], into: database)
        let latest = try database.writer.read { try $0.latestMinuteWithHeartRate(before: 240_000) }
        #expect(latest?.minuteMs == 120_000)
    }

    @Test func daySummaryComputesRestingHRHeartRateAndKcal() throws {
        let database = try AppDatabase.inMemory()
        var rows: [MinuteMetricRow] = []
        // Night: five minutes at 52 bpm give RHR 52. Daytime minutes at 80 bpm.
        for minute in 60..<70 { rows.append(minuteRow(localMs(1, minute - 60) , hr: 52, kcal: 1.5, activeKcal: 0.5)) }
        for minute in 0..<120 { rows.append(minuteRow(localMs(12) + Int64(minute) * LocalTime.msPerMinute, hr: 80, kcal: 2, activeKcal: 1)) }
        try insertMinuteRows(rows, into: database)

        let summaries = try database.writer.read { try $0.daySummaries([day], in: chicago) }
        let summary = try #require(summaries.first)
        #expect(summary.day == day)
        #expect(summary.restingHR == 52)
        #expect(summary.hrMax == 83)
        #expect(summary.kcalTotal == 10 * 1.5 + 120 * 2)
        #expect(summary.kcalActive == 10 * 0.5 + 120 * 1)
        #expect(abs(summary.coverage - Double(rows.count) / 1440) < 1e-12)
    }

    @Test func dayRollupHasNoNumbersWithoutMinutes() throws {
        let database = try AppDatabase.inMemory()
        let summary = try #require(database.writer.read { try $0.daySummaries([day], in: chicago) }.first)
        #expect(summary.restingHR == nil)
        #expect(summary.hrAvg == nil)
        #expect(summary.kcalTotal == nil)
        #expect(summary.coverage == 0)
    }

    @Test func nightRMSSDIsTheMedianOfWindowStartsOnly() throws {
        let database = try AppDatabase.inMemory()
        // Window starts at 00:00, 00:05, 00:10 carry 40, 50, 90 ms. Other minutes repeat their window's value
        // and must not count again.
        var rows: [MinuteMetricRow] = []
        for minute in 0..<15 {
            let windowIndex = minute / 5
            let value = [40.0, 50.0, 90.0][windowIndex]
            rows.append(minuteRow(localMs(0, minute), hr: 60, rmssd: value))
        }
        try insertMinuteRows(rows, into: database)
        let summary = try #require(database.writer.read { try $0.daySummaries([day], in: chicago) }.first)
        #expect(summary.rmssdNight == 50)
    }

    @Test func daySummariesFollowTheSortedDays() throws {
        let database = try AppDatabase.inMemory()
        let earlier = LocalDay(year: 2026, month: 10, day: 5)
        try insertMinuteRows([
            minuteRow(LocalTime.localTime(earlier, hour: 12, in: chicago), hr: 70, kcal: 3),
            minuteRow(localMs(12), hr: 70, kcal: 4),
        ], into: database)
        let summaries = try database.writer.read { try $0.daySummaries([day, earlier], in: chicago) }
        #expect(summaries.map(\.day) == [earlier, day])
        #expect(summaries.map(\.kcalTotal) == [3, 4])
    }

    @Test func restingHRNeedsCoverageAndAFullFiveMinuteRun() throws {
        let database = try AppDatabase.inMemory()
        // Only four minutes qualify. The run of five needs an extra minute with coverage.
        try insertMinuteRows((0..<4).map { minuteRow(localMs(2, $0), hr: 50) } + [minuteRow(localMs(2, 4), hr: 50, hrN: 30)], into: database)
        let rhr = try database.writer.read { try $0.restingHeartRate(night: day, in: chicago) }
        #expect(rhr == nil)
    }

    @Test func latestCompletedNightSwitchesAtSix() {
        let beforeSix = localMs(5, 59)
        let afterSix = localMs(6, 0)
        #expect(NightWindow.latestCompleted(nowMs: beforeSix, in: chicago) == LocalTime.adding(days: -1, to: day))
        #expect(NightWindow.latestCompleted(nowMs: afterSix, in: chicago) == day)
    }
}

struct HeartRateSeriesTests {
    @Test func bucketsAreWeightedAndSkipEstimatedMinutes() {
        let rows = [
            minuteRow(0, hr: 60, hrN: 60),
            minuteRow(60_000, hr: 90, hrN: 30),
            minuteRow(120_000, hr: nil),
            minuteRow(300_000, hr: 70, hrN: 60),
        ]
        let buckets = HeartRateSeries.buckets(rows, bucketMs: 300_000)
        #expect(buckets.map(\.startMs) == [0, 300_000])
        let first = buckets[0]
        #expect(first.sampleCount == 90)
        #expect(abs(first.avg - (60 * 60 + 90 * 30) / 90.0) < 1e-9)
        #expect(first.min == 58)
        #expect(first.max == 93)
    }

    @Test func zoneMinutesCountHRRFractions() {
        let rows = [
            minuteRow(0, hr: 60),        // HRR 5/128, below 50%
            minuteRow(60_000, hr: 138),  // 83/128 = 0.65, zone 2
            minuteRow(120_000, hr: 175), // 120/128 = 0.94, zone 5
            minuteRow(180_000, hr: nil),
        ]
        let zones = HeartRateSeries.zoneMinutes(rows, restingHR: 55, maxHR: 183)
        #expect(zones.map(\.minutes) == [1, 0, 1, 0, 0, 1])
        #expect(zones.first?.zone == .below)
    }

    @Test func zonesAreEmptyWithoutAPositiveReserve() {
        #expect(HeartRateSeries.zoneMinutes([minuteRow(0)], restingHR: 90, maxHR: 90).isEmpty)
    }
}
