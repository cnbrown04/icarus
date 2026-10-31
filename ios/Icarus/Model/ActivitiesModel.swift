import Foundation
import GRDB
import Metrics
import Store

/// Reads and labels for the Activities screens. Queries run inside `AppEnvironment.snapshots`; writes go through the
/// Store (`detectActivities`, `saveManualActivity`, `updateActivity`, `deleteActivity`).
enum ActivitiesModel {
    /// How many local days the full list reads back.
    static let listDays = 30
    private static let dayMs: Int64 = 24 * 60 * 60 * 1000

    struct ActivityDay: Sendable, Identifiable {
        let day: LocalDay
        let title: String
        let activities: [ActivityRow]

        var id: LocalDay { day }
    }

    struct ListSnapshot: Sendable {
        let days: [ActivityDay]
        let timeZone: TimeZone
    }

    struct DaySnapshot: Sendable {
        let activities: [ActivityRow]
        let timeZone: TimeZone
    }

    struct Detail: Sendable {
        let row: ActivityRow
        let timeZone: TimeZone
        let points: [HRPoint]
    }

    /// Live activities over the last `listDays` local days, newest day first.
    static func list(_ db: Database, nowMs: Int64) throws -> ListSnapshot {
        let context = try Dashboard.Context.load(db, nowMs: nowMs)
        let zone = context.timeZone
        let today = context.today
        let firstDay = LocalTime.adding(days: -(listDays - 1), to: today)
        let from = LocalTime.localTime(firstDay, hour: 0, in: zone)
        let to = LocalTime.localTime(LocalTime.adding(days: 1, to: today), hour: 0, in: zone)
        let rows = try db.activities(from: from, to: to)

        var byDay: [LocalDay: [ActivityRow]] = [:]
        for row in rows {
            byDay[LocalTime.localDay(containing: row.startMs, in: zone), default: []].append(row)
        }
        let days = byDay.keys.sorted { lhs, rhs in
            (lhs.year, lhs.month, lhs.day) > (rhs.year, rhs.month, rhs.day)
        }.map { day in
            ActivityDay(
                day: day,
                title: dayTitle(day, today: today, in: zone),
                activities: byDay[day] ?? []
            )
        }
        return ListSnapshot(days: days, timeZone: zone)
    }

    /// Live activities starting on `day`, oldest first.
    static func day(_ db: Database, day: LocalDay) throws -> DaySnapshot {
        let zone = try db.profile()?.timeZone ?? Dashboard.fallbackZone
        let from = LocalTime.localTime(day, hour: 0, in: zone)
        let to = LocalTime.localTime(LocalTime.adding(days: 1, to: day), hour: 0, in: zone)
        return DaySnapshot(activities: try db.activities(from: from, to: to), timeZone: zone)
    }

    /// One live activity with its heart-rate minutes over the span, or nil once it is deleted.
    static func detail(_ db: Database, id: String) throws -> Detail? {
        guard let row = try db.activity(id: id) else { return nil }
        let zone = try db.profile()?.timeZone ?? Dashboard.fallbackZone
        let points = try db.minuteMetricRows(from: row.startMs, to: row.endMs).compactMap { minute -> HRPoint? in
            guard let bpm = minute.hrAvg else { return nil }
            return HRPoint(date: Date(epochMs: minute.minuteMs), bpm: bpm)
        }
        return Detail(row: row, timeZone: zone, points: points)
    }

    /// Running numbers for a recording in progress: the summary of the closed minutes since `startMs`. Nil without a
    /// resting HR or HRmax, since neither strain nor kcal can be scored.
    static func liveEstimate(_ db: Database, startMs: Int64, nowMs: Int64) throws -> ActivitySummary? {
        let context = try Dashboard.Context.load(db, nowMs: nowMs)
        guard let restingHR = context.restingHR, let maxHR = context.maxHR else { return nil }
        let year = context.today.year
        let minutes = try db.minuteMetricRows(
            from: LocalTime.roundDown(startMs, to: LocalTime.msPerMinute),
            to: nowMs
        ).compactMap(\.minuteAggregate)
        return ActivitySummary.make(
            startMs: startMs,
            endMs: nowMs,
            minutes: minutes,
            restingHR: restingHR,
            maxHR: maxHR,
            profile: context.profile?.userProfile(year: year)
        )
    }

    /// Detects activities over the last two days so the list is current without waiting for a history drain.
    /// Idempotent: a run that finds nothing new writes nothing.
    static func refreshDetection(in database: AppDatabase, nowMs: Int64) async {
        _ = try? await database.writer.write { db in
            let zone = try db.profile()?.timeZone ?? Dashboard.fallbackZone
            try db.detectActivities(from: nowMs - 2 * dayMs, to: nowMs + 1, in: zone, computedAtMs: nowMs)
        }
    }

    /// "Today", "Yesterday", or a medium date in the profile's zone.
    static func dayTitle(_ day: LocalDay, today: LocalDay, in zone: TimeZone) -> String {
        if day == today { return "Today" }
        if day == LocalTime.adding(days: -1, to: today) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.timeZone = zone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: Date(epochMs: LocalTime.localTime(day, hour: 12, in: zone)))
    }

    /// Elapsed time as m:ss, or h:mm:ss from an hour on.
    static func elapsedText(seconds: Int) -> String {
        let total = max(0, seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = two(total % 60)
        if hours > 0 {
            return "\(hours.formatted()):\(two(minutes)):\(secs)"
        }
        return "\(minutes.formatted()):\(secs)"
    }

    /// Strain on the 0-21 axis, one decimal, as a bare number. A missing value is a dash.
    static func strainText(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.precision(.fractionLength(1)))
    }

    /// Kilocalories as a whole number with its unit, e.g. "320 kcal". A missing value is a dash.
    static func kcalText(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded()).formatted()) kcal"
    }

    /// A heart rate as a whole number with its unit, e.g. "128 bpm". A missing value is a dash.
    static func bpmText(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded()).formatted()) bpm"
    }

    /// Two digits, zero-padded, for clock fields.
    private static func two(_ value: Int) -> String {
        value.formatted(.number.precision(.integerLength(2)))
    }
}

extension ActivityKind {
    /// Sentence-case label for the kind picker and rows.
    var label: String {
        switch self {
        case .run: "Run"
        case .walk: "Walk"
        case .cycle: "Cycle"
        case .strength: "Strength"
        case .hiit: "HIIT"
        case .yoga: "Yoga"
        case .sport: "Sport"
        case .other: "Other"
        }
    }

    /// The glyph for a workout row, in the Activity category colour. One symbol per kind.
    var symbol: String {
        switch self {
        case .run: "figure.run"
        case .walk: "figure.walk"
        case .cycle: "figure.outdoor.cycle"
        case .strength: "figure.strengthtraining.traditional"
        case .hiit: "figure.highintensity.intervaltraining"
        case .yoga: "figure.yoga"
        case .sport: "sportscourt"
        case .other: "figure.mixed.cardio"
        }
    }
}

extension ActivityRow {
    /// The name the user gave it, else the kind's label.
    var displayName: String {
        name ?? activityKind.label
    }

    /// Zone minutes as the `ZoneBar` takes them: one entry per zone, in zone order, with whole minutes.
    var zoneTotals: [ZoneMinutes] {
        let zones: [HeartRateZone] = [.below, .zone1, .zone2, .zone3, .zone4, .zone5]
        let values = zoneMinuteValues
        return zones.enumerated().map { index, zone in
            ZoneMinutes(zone: zone, minutes: index < values.count ? Int(values[index].rounded()) : 0)
        }
    }
}
