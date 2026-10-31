import Foundation
import GRDB
import Metrics
import Store

/// What the Summary tab reads for today, in one store read: the scores behind the rings, the latest key metrics
/// (through `MetricSeries`, the same read the detail pages use), the vitals against their ranges, whether yesterday's
/// check-in needs answers, and up to two weekly highlights.
struct SummarySnapshot: Sendable {
    let timeZone: TimeZone
    let scores: DailyScores
    let vitals: VitalsBaseline
    /// The latest reading for each key metric, keyed by kind.
    let readings: [MetricKind: MetricReading]
    /// True when yesterday's check-in has no answers and at least one question is enabled.
    let journalPrompt: Bool
    /// At most two sentences from the weekly assessment. Empty when nothing moved.
    let highlights: [String]

    /// The metrics on the Summary's key metrics list, in row order.
    static let keyMetrics: [MetricKind] = [.restingHR, .hrv, .stress, .respiratoryRate]

    static func load(_ db: Database, nowMs: Int64) throws -> SummarySnapshot {
        let context = try Dashboard.Context.load(db, nowMs: nowMs)
        let zone = context.timeZone
        let today = context.today

        var readings: [MetricKind: MetricReading] = [:]
        for kind in keyMetrics {
            readings[kind] = try db.metricLatest(kind, nowMs: nowMs, in: zone)
        }

        let yesterday = LocalTime.adding(days: -1, to: today)
        let answered = try !db.answers(day: yesterday).isEmpty
        let hasQuestions = try db.journalQuestions().contains(where: \.enabled)
        let week = try CoachingModel.loadWeek(db, nowMs: nowMs)

        return SummarySnapshot(
            timeZone: zone,
            scores: try db.dailyScores(day: today, in: zone),
            vitals: try db.vitalsBaseline(day: today, in: zone),
            readings: readings,
            journalPrompt: hasQuestions && !answered,
            highlights: Array(week.observations.prefix(2))
        )
    }
}
