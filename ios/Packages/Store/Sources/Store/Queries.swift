import Foundation
import GRDB
import Metrics

/// Read paths. Use them inside `AppDatabase.observe` or `DatabaseReader.read`. Ranges are half-open.
extension Database {
    public func heartRateRows(from fromMs: Int64, to toMs: Int64) throws -> [HeartRateRow] {
        try HeartRateRow.fetchAll(self, sql: """
        SELECT * FROM hr_sample WHERE ts_ms >= ? AND ts_ms < ? ORDER BY ts_ms, rowid
        """, arguments: [fromMs, toMs])
    }

    /// Accepted R-R intervals in arrival order (rowid order).
    public func acceptedRRRows(from fromMs: Int64, to toMs: Int64) throws -> [RRIntervalRow] {
        try RRIntervalRow.fetchAll(self, sql: """
        SELECT * FROM rr_interval WHERE accepted = 1 AND ts_ms >= ? AND ts_ms < ? ORDER BY rowid
        """, arguments: [fromMs, toMs])
    }

    public func minuteMetricRows(from fromMs: Int64, to toMs: Int64) throws -> [MinuteMetricRow] {
        try MinuteMetricRow.fetchAll(self, sql: """
        SELECT * FROM minute_metric WHERE minute_ms >= ? AND minute_ms < ? ORDER BY minute_ms
        """, arguments: [fromMs, toMs])
    }

    /// The most recent minute before `beforeMs` that has heart-rate samples.
    public func latestMinuteWithHeartRate(before beforeMs: Int64) throws -> MinuteMetricRow? {
        try MinuteMetricRow.fetchOne(self, sql: """
        SELECT * FROM minute_metric WHERE minute_ms < ? AND hr_avg IS NOT NULL ORDER BY minute_ms DESC LIMIT 1
        """, arguments: [beforeMs])
    }

    /// Resting HR for the night of `day` (00:00-06:00 local), or nil when no 5-minute run qualifies (PLAN.md 8.1).
    public func restingHeartRate(night day: LocalDay, in timeZone: TimeZone) throws -> Double? {
        let night = LocalTime.nightWindow(of: day, in: timeZone)
        let rows = try minuteMetricRows(from: night.lowerBound, to: night.upperBound)
        return RestingHR.lowestWindowMean(rows.compactMap(\.minuteAggregate), in: night)
    }

    /// Local-day rollups for `days`, computed from the minute rows (PLAN.md 10.3 `daily_summaries`, derived here).
    public func daySummaries(_ days: [LocalDay], in timeZone: TimeZone) throws -> [DaySummary] {
        let ordered = DailyRollup.sortedUnique(days)
        guard let first = ordered.first, let last = ordered.last else { return [] }
        let from = LocalTime.localTime(first, hour: 0, in: timeZone)
        let to = LocalTime.localTime(LocalTime.adding(days: 1, to: last), hour: 0, in: timeZone)
        let rows = try minuteMetricRows(from: from, to: to)
        return DailyRollup.summaries(days: days, minutes: rows, in: timeZone)
    }
}
