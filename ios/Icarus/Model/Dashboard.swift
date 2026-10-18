import Foundation
import GRDB
import Metrics
import Store

/// Read models for the data screens (PLAN.md §14 rows 7-11). Each `load` runs inside one read so the
/// numbers on a screen come from the same snapshot.
enum Dashboard {
    /// The profile's zone, or the default when no profile exists yet.
    static let fallbackZone = TimeZone(identifier: "America/Chicago")!

    /// Stress bars are 15-minute averages on every screen that shows them.
    static let stressBucketMs: Int64 = 15 * LocalTime.msPerMinute

    /// HRmax for zones and calorie inputs: user-entered, else Tanaka from birth year (PLAN.md 8.1).
    static func maxHR(_ profile: ProfileRow, year: Int) -> Double? {
        if let hrMax = profile.hrMax {
            return Double(hrMax)
        }
        guard let birthYear = profile.birthYear else { return nil }
        return HeartRateZones.maxHR(userEntered: nil, ageYears: max(0, year - birthYear))
    }

    /// Profile, zone, last night's resting HR and HRmax. Shared by every screen.
    struct Context: Sendable {
        let profile: ProfileRow?
        let timeZone: TimeZone
        let nowMs: Int64
        let restingHR: Double?
        let maxHR: Double?

        static func load(_ db: Database, nowMs: Int64) throws -> Context {
            let profile = try db.profile()
            let zone = profile?.timeZone ?? fallbackZone
            let night = NightWindow.latestCompleted(nowMs: nowMs, in: zone)
            let year = LocalTime.localDay(containing: nowMs, in: zone).year
            return Context(
                profile: profile,
                timeZone: zone,
                nowMs: nowMs,
                restingHR: try db.restingHeartRate(night: night, in: zone),
                maxHR: profile.flatMap { Dashboard.maxHR($0, year: year) }
            )
        }

        var today: LocalDay {
            LocalTime.localDay(containing: nowMs, in: timeZone)
        }
    }

    /// Seven local days ending today, oldest first.
    static func weekDays(_ context: Context) -> [LocalDay] {
        (0..<7).reversed().map { LocalTime.adding(days: -$0, to: context.today) }
    }

    /// Zones for `rows`. Empty until the profile gives both HRmax and last night's resting HR.
    static func zoneMinutes(_ rows: [MinuteMetricRow], context: Context) -> [ZoneMinutes] {
        guard let restingHR = context.restingHR, let maxHR = context.maxHR else { return [] }
        return HeartRateSeries.zoneMinutes(rows, restingHR: restingHR, maxHR: maxHR)
    }

    static func stressSamples(_ rows: [MinuteMetricRow]) -> [(ms: Int64, value: Int)] {
        rows.compactMap { row in row.stress.map { (ms: row.minuteMs, value: $0) } }
    }

    // MARK: Today

    struct TodaySnapshot: Sendable {
        struct Point: Sendable, Identifiable {
            let id: Int64
            let date: Date
            let bpm: Int
        }

        let context: Context
        /// Raw samples for the last 15 minutes.
        let sparkline: [Point]
        /// The newest minute row, if any minute was computed in the last 10 minutes.
        let latestMinute: MinuteMetricRow?
        let today: DaySummary?
        /// Stress for the local day so far, in 15-minute buckets.
        let stressBuckets: [StressBucket]
        /// Heart-rate zones for the local day so far.
        let zones: [ZoneMinutes]
        /// Seven local days, oldest first, ending today.
        let week: [DaySummary]
    }

    static func today(_ db: Database, nowMs: Int64) throws -> TodaySnapshot {
        let context = try Context.load(db, nowMs: nowMs)
        let samples = try db.heartRateRows(from: nowMs - 15 * LocalTime.msPerMinute, to: nowMs)
        let recent = try db.minuteMetricRows(from: nowMs - 10 * LocalTime.msPerMinute, to: nowMs)
        let dayStart = LocalTime.localTime(context.today, hour: 0, in: context.timeZone)
        let dayRows = try db.minuteMetricRows(from: dayStart, to: nowMs)
        return TodaySnapshot(
            context: context,
            sparkline: samples.map { TodaySnapshot.Point(id: $0.rowid, date: Date(epochMs: $0.tsMs), bpm: $0.bpm) },
            latestMinute: recent.last,
            today: try db.daySummaries([context.today], in: context.timeZone).first,
            stressBuckets: StressBuckets.make(stressSamples(dayRows), bucketMs: stressBucketMs),
            zones: zoneMinutes(dayRows, context: context),
            week: try db.daySummaries(weekDays(context), in: context.timeZone)
        )
    }

    // MARK: Heart rate

    enum HeartRateRange: String, CaseIterable, Identifiable, Sendable {
        case hour
        case sixHours
        case day
        case week

        var id: String { rawValue }

        var label: String {
            switch self {
            case .hour: "1 h"
            case .sixHours: "6 h"
            case .day: "24 h"
            case .week: "7 d"
            }
        }

        var durationMs: Int64 {
            switch self {
            case .hour: 1 * LocalTime.msPerMinute * 60
            case .sixHours: 6 * LocalTime.msPerMinute * 60
            case .day: 24 * LocalTime.msPerMinute * 60
            case .week: 7 * 24 * LocalTime.msPerMinute * 60
            }
        }

        /// Bucket width that keeps each chart near 100 points.
        var bucketMs: Int64 {
            switch self {
            case .hour: LocalTime.msPerMinute
            case .sixHours: 5 * LocalTime.msPerMinute
            case .day: 15 * LocalTime.msPerMinute
            case .week: 60 * LocalTime.msPerMinute
            }
        }
    }

    struct HeartRateSnapshot: Sendable {
        let range: HeartRateRange
        let buckets: [HeartRateBucket]
        let zones: [ZoneMinutes]
        let minimum: Int?
        let average: Double?
        let maximum: Int?
        let context: Context
    }

    static func heartRate(_ db: Database, nowMs: Int64, range: HeartRateRange) throws -> HeartRateSnapshot {
        let context = try Context.load(db, nowMs: nowMs)
        let rows = try db.minuteMetricRows(from: nowMs - range.durationMs, to: nowMs)
        let withHR = rows.filter { $0.hrAvg != nil }
        let count = withHR.reduce(0) { $0 + $1.hrN }
        return HeartRateSnapshot(
            range: range,
            buckets: HeartRateSeries.buckets(withHR, bucketMs: range.bucketMs),
            zones: zoneMinutes(withHR, context: context),
            minimum: withHR.compactMap(\.hrMin).min(),
            average: count > 0 ? withHR.reduce(0.0) { $0 + ($1.hrAvg ?? 0) * Double($1.hrN) } / Double(count) : nil,
            maximum: withHR.compactMap(\.hrMax).max(),
            context: context
        )
    }

    // MARK: Stress

    struct StressSnapshot: Sendable {
        /// The last 24 hours in 15-minute buckets.
        let buckets: [StressBucket]
        let latest: MinuteMetricRow?
        /// RMSSD and sqrt(Baevsky) from the newest valid window in the last 24 h.
        let rmssd: Double?
        let baevskySqrt: Double?
        /// Seven local days, oldest first, ending today.
        let week: [DaySummary]
        let context: Context
    }

    static func stress(_ db: Database, nowMs: Int64) throws -> StressSnapshot {
        let context = try Context.load(db, nowMs: nowMs)
        let rows = try db.minuteMetricRows(from: nowMs - 24 * 60 * LocalTime.msPerMinute, to: nowMs)
        return StressSnapshot(
            buckets: StressBuckets.make(stressSamples(rows), bucketMs: stressBucketMs),
            latest: rows.last,
            rmssd: rows.last(where: { $0.rmssdMs != nil })?.rmssdMs,
            baevskySqrt: rows.last(where: { $0.baevskySqrt != nil })?.baevskySqrt,
            week: try db.daySummaries(weekDays(context), in: context.timeZone),
            context: context
        )
    }

    // MARK: Calories

    struct CaloriesSnapshot: Sendable {
        struct Hour: Sendable, Identifiable {
            let id: Int
            let resting: Double
            let active: Double
        }

        let total: Double?
        let active: Double?
        let hours: [Hour]
        /// Seven local days, oldest first, ending today.
        let week: [DaySummary]
        let context: Context
    }

    static func calories(_ db: Database, nowMs: Int64) throws -> CaloriesSnapshot {
        let context = try Context.load(db, nowMs: nowMs)
        let dayStart = LocalTime.localTime(context.today, hour: 0, in: context.timeZone)
        let dayEnd = LocalTime.localTime(LocalTime.adding(days: 1, to: context.today), hour: 0, in: context.timeZone)
        let rows = try db.minuteMetricRows(from: dayStart, to: min(dayEnd, nowMs))
        var resting = Array(repeating: 0.0, count: 24)
        var active = Array(repeating: 0.0, count: 24)
        for row in rows {
            let hour = min(Int((row.minuteMs - dayStart) / (60 * LocalTime.msPerMinute)), 23)
            resting[hour] += row.kcal - row.activeKcal
            active[hour] += row.activeKcal
        }
        let summary = try db.daySummaries([context.today], in: context.timeZone).first
        return CaloriesSnapshot(
            total: summary?.kcalTotal,
            active: summary?.kcalActive,
            hours: (0..<24).map { CaloriesSnapshot.Hour(id: $0, resting: resting[$0], active: active[$0]) },
            week: try db.daySummaries(weekDays(context), in: context.timeZone),
            context: context
        )
    }

    // MARK: Trends

    struct TrendsSnapshot: Sendable {
        /// Oldest first, one entry per local day, including days with no data.
        let days: [DaySummary]
        let context: Context
    }

    /// `dayCount` days ending today. Trends passes twice the span, so the earlier half is the previous period.
    static func trends(_ db: Database, nowMs: Int64, dayCount: Int) throws -> TrendsSnapshot {
        let context = try Context.load(db, nowMs: nowMs)
        let days = (0..<dayCount).map { LocalTime.adding(days: -$0, to: context.today) }
        return TrendsSnapshot(
            days: try db.daySummaries(days, in: context.timeZone),
            context: context
        )
    }
}
