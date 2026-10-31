import Foundation
import GRDB
import Metrics
import Store
import SwiftUI

/// What the Health screens read in one store pass. Day-scoped values are for `day`. `series` holds the
/// per-day scores for the window ending on `day`, oldest first, and is empty when none were asked for.
struct HealthSnapshot: Sendable {
    let timeZone: TimeZone
    let day: LocalDay
    let scores: DailyScores
    let vitals: VitalsBaseline
    let series: [DailyScorePoint]

    /// `requested` nil means today in the profile's zone. `seriesDays` is the number of days of `series`.
    static func load(_ db: Database, nowMs: Int64, day requested: LocalDay?, seriesDays: Int) throws -> HealthSnapshot {
        let context = try Dashboard.Context.load(db, nowMs: nowMs)
        let day = requested ?? context.today
        let scores = try db.dailyScores(day: day, in: context.timeZone)
        let vitals = try db.vitalsBaseline(day: day, in: context.timeZone)
        var series: [DailyScorePoint] = []
        if seriesDays > 0 {
            series = try db.dailyScoreSeries(
                from: LocalTime.adding(days: 1 - seriesDays, to: day),
                through: day,
                in: context.timeZone
            )
        }
        return HealthSnapshot(timeZone: context.timeZone, day: day, scores: scores, vitals: vitals, series: series)
    }

    /// The day as a medium date in this snapshot's zone, e.g. "Oct 20, 2026".
    var dayLabel: String {
        Self.label(day, in: timeZone)
    }

    static func label(_ day: LocalDay, in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: Date(epochMs: LocalTime.localTime(day, hour: 12, in: timeZone)))
    }
}

/// Recovery as the Home tile reads it: the score, its band colour and the calibration caption. The
/// calibration bar is `Recovery.minNightsTrust`, the same 14 nights Home uses.
struct RecoveryReadout {
    let outcome: Recovery.Outcome?

    private var score: Recovery.Score? {
        if case let .scored(score)? = outcome { return score }
        return nil
    }

    /// Score as a whole number, or an em dash while no score exists.
    var value: String {
        score.map { "\(Int($0.score.rounded()))" } ?? "—"
    }

    /// The score as a fraction for a ring. Zero when there is no score.
    var fraction: Double {
        (score?.score ?? 0) / 100
    }

    var hasScore: Bool { score != nil }

    var tint: Color {
        score.map { Palette.recovery($0.band) } ?? Palette.neutral
    }

    var isCalibrating: Bool {
        switch outcome {
        case let .scored(score)?: score.hrvBaseline.nValid < Recovery.minNightsTrust
        case .insufficientBaseline?: true
        case nil: false
        }
    }

    var caption: String {
        switch outcome {
        case let .scored(score)?:
            let nights = score.hrvBaseline.nValid
            return nights < Recovery.minNightsTrust
                ? "Calibrating · \(nights)/\(Recovery.minNightsTrust) nights"
                : "From last night"
        case let .insufficientBaseline(_, validNights)?:
            return "Calibrating · \(validNights)/\(Recovery.minNightsTrust) nights"
        case nil:
            return "No night yet"
        }
    }

    var summary: String {
        hasScore ? "Recovery \(value) percent, \(caption)" : "Recovery, \(caption)"
    }
}

extension HealthMonitor.Vital {
    var title: String {
        switch self {
        case .restingHR: "Resting Heart Rate"
        case .hrv: "Heart Rate Variability"
        case .respiratoryRate: "Respiratory Rate"
        }
    }

    /// Unit shown after a value.
    var unit: String {
        switch self {
        case .restingHR: "bpm"
        case .hrv: "ms"
        case .respiratoryRate: "br/min"
        }
    }

    /// The number alone, in display precision: whole bpm and ms, one decimal for breaths.
    func number(_ value: Double) -> String {
        switch self {
        case .restingHR, .hrv: Int(value.rounded()).formatted()
        case .respiratoryRate: value.formatted(.number.precision(.fractionLength(1)))
        }
    }

    /// A value with its unit, such as "62 bpm".
    func text(_ value: Double) -> String {
        "\(number(value)) \(unit)"
    }

    /// A range with one unit, such as "60–69 bpm".
    func rangeText(_ low: Double, _ high: Double) -> String {
        "\(number(low))–\(number(high)) \(unit)"
    }
}
