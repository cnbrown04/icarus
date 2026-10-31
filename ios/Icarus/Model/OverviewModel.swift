import Foundation
import GRDB
import Metrics
import Store

/// What the Overview reads for one selected day, in one store read. Scores and vitals come from `HealthSnapshot`,
/// so the dials and the Health cards agree. `daysBack` 0 is today; the pager steps it.
struct OverviewSnapshot: Sendable {
    let health: HealthSnapshot
    let daysBack: Int
    /// True when yesterday's check-in has no answers and today is selected. Shows the "Log yesterday" card.
    let journalPrompt: Bool

    var day: LocalDay { health.day }
    var isToday: Bool { daysBack == 0 }

    static func load(_ db: Database, nowMs: Int64, daysBack: Int) throws -> OverviewSnapshot {
        let context = try Dashboard.Context.load(db, nowMs: nowMs)
        let day = LocalTime.adding(days: -daysBack, to: context.today)
        let health = try HealthSnapshot.load(db, nowMs: nowMs, day: day, seriesDays: 0)
        let yesterday = LocalTime.adding(days: -1, to: context.today)
        let answered = try !db.answers(day: yesterday).isEmpty
        let hasQuestions = try db.journalQuestions().contains(where: \.enabled)
        return OverviewSnapshot(
            health: health,
            daysBack: daysBack,
            journalPrompt: daysBack == 0 && hasQuestions && !answered
        )
    }
}

/// Today's heart and stress numbers for the Health tab: resting HR, HRV, the latest stress value and the stress
/// timeline for the day so far, with the stimulant windows that overlap it.
struct HealthTodaySnapshot: Sendable {
    let timeZone: TimeZone
    let restingHR: Double?
    let rmssd: Double?
    let latestStress: Int?
    let stressState: StressState?
    let stressDay: StressDaySummary
    let calibration: StressCalibrationProgress
    let stressTimeline: [StressTimelinePoint]
    let dayStartMs: Int64
    let nowMs: Int64
    let medication: [MedicationWindow]

    static func load(_ db: Database, nowMs: Int64) throws -> HealthTodaySnapshot {
        let today = try Dashboard.today(db, nowMs: nowMs)
        let zone = today.context.timeZone
        let dayStart = LocalTime.localTime(today.context.today, hour: 0, in: zone)
        let timeline = try Dashboard.stressTimeline(db, nowMs: nowMs, fromMs: dayStart)
        let windows = try db.medicationWindows(
            from: LocalTime.adding(days: -1, to: today.context.today),
            to: today.context.today,
            in: zone
        )
        return HealthTodaySnapshot(
            timeZone: zone,
            restingHR: today.today?.restingHR ?? today.context.restingHR,
            rmssd: today.today?.rmssdNight,
            latestStress: today.latestMinute?.stress ?? timeline.last(where: { $0.stress != nil })?.stress,
            stressState: today.latestMinute?.state ?? timeline.last?.state,
            stressDay: today.stressDay,
            calibration: try Dashboard.stressCalibration(db, nowMs: nowMs, context: today.context),
            stressTimeline: timeline,
            dayStartMs: dayStart,
            nowMs: nowMs,
            medication: windows
        )
    }
}
