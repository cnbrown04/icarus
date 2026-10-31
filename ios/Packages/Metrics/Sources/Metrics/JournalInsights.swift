import Foundation

/// Journal behaviour vs next-morning outcome comparisons (WHOOP-style "with vs without").
///
/// Each behaviour (a journal question id, or a medication id) is split into the days it was answered yes and the
/// days it was answered no. For each outcome metric the mean on each side is compared. The comparison is
/// CORRELATION ONLY: a day on which someone drank alcohol also differs in many other ways, so a gap here does not
/// show that the behaviour caused it. Nothing is shown until both sides hold `minimumDaysPerSide` days.
public enum JournalInsights {
    /// Days each side needs before an effect is shown.
    public static let minimumDaysPerSide = 5

    /// An outcome measured the morning after a journal day.
    public enum Metric: String, Sendable, Equatable, CaseIterable {
        case recovery
        case sleepPerformance
        case hrv

        public var label: String {
            switch self {
            case .recovery: "Recovery"
            case .sleepPerformance: "Sleep performance"
            case .hrv: "HRV"
            }
        }

        public var unit: String {
            switch self {
            case .recovery, .sleepPerformance: "%"
            case .hrv: "ms"
            }
        }
    }

    /// Next-morning outcomes for one day. Each value is nil when that measurement is missing.
    public struct Outcome: Sendable, Equatable {
        public var recoveryPct: Double?
        public var sleepPerformancePct: Double?
        public var hrvMs: Double?

        public init(recoveryPct: Double? = nil, sleepPerformancePct: Double? = nil, hrvMs: Double? = nil) {
            self.recoveryPct = recoveryPct
            self.sleepPerformancePct = sleepPerformancePct
            self.hrvMs = hrvMs
        }

        public func value(for metric: Metric) -> Double? {
            switch metric {
            case .recovery: recoveryPct
            case .sleepPerformance: sleepPerformancePct
            case .hrv: hrvMs
            }
        }
    }

    /// One journal day: the answers given for it (behaviour id to `true` for yes, `false` for no; an absent id was
    /// not answered and counts on neither side) and the outcome of the following morning.
    public struct Day: Sendable, Equatable {
        public var behaviours: [String: Bool]
        public var outcome: Outcome

        public init(behaviours: [String: Bool], outcome: Outcome) {
            self.behaviours = behaviours
            self.outcome = outcome
        }
    }

    /// Mean and sample standard deviation of one side of a comparison. Nil when it has no days (mean) or fewer
    /// than two (SD).
    public struct Side: Sendable, Equatable {
        public var days: Int
        public var mean: Double?
        public var standardDeviation: Double?
    }

    /// The comparison for one behaviour and one metric.
    public struct Effect: Sendable, Equatable {
        public var behaviour: String
        public var metric: Metric
        /// Days answered yes, with an outcome for the metric.
        public var with: Side
        /// Days answered no, with an outcome for the metric.
        public var without: Side

        public init(behaviour: String, metric: Metric, with: Side, without: Side) {
            self.behaviour = behaviour
            self.metric = metric
            self.with = with
            self.without = without
        }

        /// `with.mean - without.mean`, in the metric's unit. Nil when either side is empty.
        public var difference: Double? {
            guard let yes = with.mean, let no = without.mean else { return nil }
            return yes - no
        }

        /// `difference` divided by the pooled standard deviation (Cohen's d). Nil when either side has fewer
        /// than two days or the pooled SD is zero.
        public var effectSize: Double? {
            guard let difference, with.days >= 2, without.days >= 2,
                  let sdYes = with.standardDeviation, let sdNo = without.standardDeviation else { return nil }
            let pooledVariance = (Double(with.days - 1) * sdYes * sdYes + Double(without.days - 1) * sdNo * sdNo)
                / Double(with.days + without.days - 2)
            let pooled = pooledVariance.squareRoot()
            guard pooled > 0 else { return nil }
            return difference / pooled
        }

        /// True when both sides reach `minimumDaysPerSide`, the only state in which the UI shows the effect.
        public var isConfident: Bool {
            difference != nil && with.days >= JournalInsights.minimumDaysPerSide
                && without.days >= JournalInsights.minimumDaysPerSide
        }

        /// Days still needed on the thinner side. Zero when the effect is confident.
        public var moreDaysNeeded: Int {
            max(0, JournalInsights.minimumDaysPerSide - min(with.days, without.days))
        }
    }

    /// One effect per behaviour and metric, for every behaviour that appears in `days`. Behaviours are ordered
    /// by id, then metrics in `Metric.allCases` order.
    public static func effects(for days: [Day]) -> [Effect] {
        let behaviours = Set(days.flatMap { $0.behaviours.keys }).sorted()
        var effects: [Effect] = []
        for behaviour in behaviours {
            for metric in Metric.allCases {
                var yes: [Double] = []
                var no: [Double] = []
                for day in days {
                    guard let answer = day.behaviours[behaviour], let value = day.outcome.value(for: metric) else {
                        continue
                    }
                    if answer { yes.append(value) } else { no.append(value) }
                }
                effects.append(Effect(behaviour: behaviour, metric: metric, with: side(yes), without: side(no)))
            }
        }
        return effects
    }

    private static func side(_ values: [Double]) -> Side {
        guard !values.isEmpty else { return Side(days: 0, mean: nil, standardDeviation: nil) }
        let mean = values.reduce(0, +) / Double(values.count)
        guard values.count >= 2 else { return Side(days: values.count, mean: mean, standardDeviation: nil) }
        let squares = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        return Side(
            days: values.count,
            mean: mean,
            standardDeviation: (squares / Double(values.count - 1)).squareRoot()
        )
    }
}
