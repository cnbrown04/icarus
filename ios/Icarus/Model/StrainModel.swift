import Foundation
import GRDB
import Metrics
import Store

/// Read models for the Strain tab and the coaching cards. Each `load` runs inside one read, so the numbers on a
/// screen come from the same snapshot. The rules live in Metrics and Store; this file only assembles them.
enum StrainModel {
    /// What the Strain tab shows for the local day.
    struct Snapshot: Sendable {
        /// Today's live numbers: last 15 minutes of heart rate, zone minutes, calories, the 7-day window.
        let today: Dashboard.TodaySnapshot
        /// Today's zone runs for the timeline chart.
        let zoneTimeline: HRZoneTimeline
        /// Local midnight in epoch ms, the left edge of the day charts.
        let dayStartMs: Int64
        /// Day strain, recovery, tonight's need and the planned wake time.
        let coaching: CoachingInputs
        let timeZone: TimeZone
    }

    static func load(_ db: Database, nowMs: Int64) throws -> Snapshot {
        let today = try Dashboard.today(db, nowMs: nowMs)
        let zone = today.context.timeZone
        let dayStart = LocalTime.localTime(today.context.today, hour: 0, in: zone)
        return Snapshot(
            today: today,
            zoneTimeline: try Dashboard.hrZoneTimeline(db, nowMs: nowMs, fromMs: dayStart, context: today.context),
            dayStartMs: dayStart,
            coaching: try db.coachingInputs(nowMs: nowMs, in: zone),
            timeZone: zone
        )
    }
}

/// Coaching inputs for the Sleep Planner card and the Weekly Assessment, with the zone they were read in.
enum CoachingModel {
    struct Snapshot: Sendable {
        let inputs: CoachingInputs
        let timeZone: TimeZone
    }

    static func load(_ db: Database, nowMs: Int64) throws -> Snapshot {
        let zone = try Dashboard.Context.load(db, nowMs: nowMs).timeZone
        return Snapshot(inputs: try db.coachingInputs(nowMs: nowMs, in: zone), timeZone: zone)
    }

    /// Last seven full days against the seven before, as the Weekly Assessment table and observations.
    static func loadWeek(_ db: Database, nowMs: Int64) throws -> WeeklyAssessment.Report {
        let zone = try Dashboard.Context.load(db, nowMs: nowMs).timeZone
        let days = try db.weeklyDays(nowMs: nowMs, in: zone)
        return WeeklyAssessment.report(thisWeek: days.thisWeek, previousWeek: days.previousWeek)
    }
}

/// Plays the target-reached buzz at most once a day. The crossing rule is `TargetBuzzGate` (Metrics); this type
/// keeps the fired day in UserDefaults, so a relaunch on the same day stays quiet.
///
/// The gate records every crossing, even while the Settings toggle is off, so a day's buzz is used up by the
/// first crossing that day. Turning the toggle on later that day does not buzz for an earlier crossing.
@MainActor
final class TargetBuzzController {
    /// Settings toggle, default off.
    static let enabledKey = "coach.buzzOnTarget"
    /// The last day a buzz fired, as "yyyy-MM-dd".
    static let firedDayKey = "coach.buzzFiredDay"

    private var gate: TargetBuzzGate
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        gate = TargetBuzzGate(firedDay: Self.decode(defaults.string(forKey: Self.firedDayKey)))
    }

    /// Records one strain observation. Returns true when the caller should play the buzz now.
    func observe(strain: Double?, target: StrainTarget?, day: LocalDay) -> Bool {
        let before = gate.firedDay
        let fire = gate.observe(strain: strain, target: target, day: day)
        if gate.firedDay != before, let fired = gate.firedDay {
            defaults.set(Self.encode(fired), forKey: Self.firedDayKey)
        }
        return fire
    }

    static func encode(_ day: LocalDay) -> String {
        String(format: "%04ld-%02ld-%02ld", day.year, day.month, day.day)
    }

    static func decode(_ text: String?) -> LocalDay? {
        guard let text else { return nil }
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return LocalDay(year: parts[0], month: parts[1], day: parts[2])
    }
}
