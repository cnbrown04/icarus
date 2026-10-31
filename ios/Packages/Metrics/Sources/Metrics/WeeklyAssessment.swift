import Foundation

// WeeklyAssessment.swift: last week against the week before, one row per metric and up to three
// observations.
//
// Inputs are the per-day values the scores already produce (`DailyScores`, `DaySummary`). Averages need
// `minimumDays` valid days in a week, so one stray night does not stand for the week. Observations name a
// metric only when its change clears that metric's `threshold`, which we chose by eye. They are our
// wording, not WHOOP's.

public enum WeeklyAssessment {
    /// Days with a value a week needs before its average is shown.
    public static let minimumDays = 3
    /// Observations shown at most.
    public static let maxObservations = 3

    /// One local day's values. Nil means no value that day.
    public struct Day: Equatable, Sendable {
        /// Recovery, 0 to 100.
        public let recovery: Double?
        /// Sleep performance, 0 to 100.
        public let sleepPerformance: Double?
        /// Asleep time of the main sleep that ended that day, in hours.
        public let hoursSlept: Double?
        /// Day strain on WHOOP's 0 to 21 axis.
        public let strain: Double?
        /// Nightly RMSSD, ms.
        public let hrv: Double?
        /// Nightly resting HR, bpm.
        public let restingHR: Double?

        public init(
            recovery: Double? = nil,
            sleepPerformance: Double? = nil,
            hoursSlept: Double? = nil,
            strain: Double? = nil,
            hrv: Double? = nil,
            restingHR: Double? = nil
        ) {
            self.recovery = recovery
            self.sleepPerformance = sleepPerformance
            self.hoursSlept = hoursSlept
            self.strain = strain
            self.hrv = hrv
            self.restingHR = restingHR
        }
    }

    /// A table row. Nil averages mean too few days.
    public enum Metric: String, CaseIterable, Sendable {
        case recovery
        case sleepPerformance
        case hoursSlept
        case strain
        case hrv
        case restingHR

        public var title: String {
            switch self {
            case .recovery: "Recovery"
            case .sleepPerformance: "Sleep performance"
            case .hoursSlept: "Hours slept"
            case .strain: "Strain"
            case .hrv: "HRV"
            case .restingHR: "Resting HR"
            }
        }

        public var unit: String {
            switch self {
            case .recovery, .sleepPerformance: "%"
            case .hoursSlept: "h"
            case .strain: ""
            case .hrv: "ms"
            case .restingHR: "bpm"
            }
        }

        /// Higher is better for recovery, sleep, hours and HRV. Lower is better for resting HR. Strain has no
        /// direction, so it is reported without a judgement.
        public var higherIsBetter: Bool? {
            switch self {
            case .recovery, .sleepPerformance, .hoursSlept, .hrv: true
            case .restingHR: false
            case .strain: nil
            }
        }

        /// The change that counts as a real move, in the metric's unit.
        public var threshold: Double {
            switch self {
            case .recovery: 5
            case .sleepPerformance: 5
            case .hoursSlept: 0.5
            case .strain: 2
            case .hrv: 5
            case .restingHR: 3
            }
        }

        public func value(in day: Day) -> Double? {
            switch self {
            case .recovery: day.recovery
            case .sleepPerformance: day.sleepPerformance
            case .hoursSlept: day.hoursSlept
            case .strain: day.strain
            case .hrv: day.hrv
            case .restingHR: day.restingHR
            }
        }
    }

    /// One metric's row in the table.
    public struct Row: Equatable, Sendable {
        public let metric: Metric
        public let thisWeek: Double?
        public let previousWeek: Double?
        /// `thisWeek - previousWeek`, when both exist.
        public let delta: Double?

        public init(metric: Metric, thisWeek: Double?, previousWeek: Double?, delta: Double?) {
            self.metric = metric
            self.thisWeek = thisWeek
            self.previousWeek = previousWeek
            self.delta = delta
        }
    }

    public struct Report: Equatable, Sendable {
        public let rows: [Row]
        /// At most `maxObservations` sentences, most significant first. Empty when nothing moved.
        public let observations: [String]
        public let thisWeekDays: Int
        public let previousWeekDays: Int
    }

    /// The report for two seven-day series, oldest first. Each series should hold one entry per local day.
    public static func report(thisWeek: [Day], previousWeek: [Day]) -> Report {
        let rows = Metric.allCases.map { metric in
            let current = average(thisWeek.compactMap { metric.value(in: $0) })
            let previous = average(previousWeek.compactMap { metric.value(in: $0) })
            return Row(
                metric: metric,
                thisWeek: current,
                previousWeek: previous,
                delta: current.flatMap { c in previous.map { c - $0 } }
            )
        }
        return Report(
            rows: rows,
            observations: observations(for: rows),
            thisWeekDays: thisWeek.filter(hasAnyValue).count,
            previousWeekDays: previousWeek.filter(hasAnyValue).count
        )
    }

    /// Sentences for the rows whose change clears the threshold, most significant first, at most three.
    /// Significance is the change in threshold units.
    public static func observations(for rows: [Row]) -> [String] {
        rows
            .compactMap { row -> (row: Row, score: Double)? in
                guard let delta = row.delta, abs(delta) >= row.metric.threshold else { return nil }
                return (row, abs(delta) / row.metric.threshold)
            }
            .sorted { $0.score > $1.score }
            .prefix(maxObservations)
            .map { sentence(for: $0.row) }
    }

    // MARK: - Internals

    /// Mean of `values` when there are at least `minimumDays` of them, else nil.
    static func average(_ values: [Double]) -> Double? {
        let finite = values.filter(\.isFinite)
        guard finite.count >= minimumDays else { return nil }
        return finite.reduce(0, +) / Double(finite.count)
    }

    static func hasAnyValue(_ day: Day) -> Bool {
        Metric.allCases.contains { $0.value(in: day) != nil }
    }

    /// Numbers first, then the change. e.g. "HRV averaged 48 ms, down 7 ms from the week before." A change in a
    /// percentage is in points ("up 30 points"): "up 30%" would read as a relative change.
    /// Only called for rows whose delta clears the threshold.
    static func sentence(for row: Row) -> String {
        guard let current = row.thisWeek, let delta = row.delta else { return "" }
        let direction = delta > 0 ? "up" : "down"
        let value = format(current, unit: row.metric.unit)
        let change = row.metric.unit == "%"
            ? "\(Int(abs(delta).rounded())) points"
            : format(abs(delta), unit: row.metric.unit)
        return "\(row.metric.title) averaged \(value), \(direction) \(change) from the week before."
    }

    /// "92%" (no space before a percent sign), "9.0 h", "48 ms", "11.4" (strain has no unit).
    static func format(_ value: Double, unit: String) -> String {
        let text = unit == "h" || unit.isEmpty
            ? value.formatted(.number.precision(.fractionLength(1)))
            : "\(Int(value.rounded()))"
        if unit.isEmpty { return text }
        return unit == "%" ? "\(text)%" : "\(text) \(unit)"
    }
}
