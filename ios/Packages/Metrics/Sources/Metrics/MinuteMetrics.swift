/// One row of the `minute_metric` table (PLAN.md 10.2), without the store-only columns
/// `computed_at` and `sync_rev`.
public struct MinuteMetric: Sendable, Equatable {
    public let minuteMs: Int64
    public let hrAvg: Double?
    public let hrMin: Int?
    public let hrMax: Int?
    public let hrN: Int
    public let rmssdMs: Double?
    public let sdnnMs: Double?
    public let baevskySqrt: Double?
    public let stress: Int?
    public let stressState: StressState
    public let kcal: Double
    public let activeKcal: Double
    public let kcalEstimated: Bool
    /// TODO(PLAN.md 10.2 vs 8.5): the table has one `algo_version` column, but 8.5 versions each
    /// family. The store must decide how to encode this.
    public let algoVersion: AlgoVersion
}

/// Inputs that are the same for every minute in a calculation.
public struct MinuteMetricsContext: Sendable, Equatable {
    public let profile: UserProfile
    /// Nil until a night's RHR exists. Kcal then uses the HR_flex floor of 90 bpm.
    public let restingHR: Double?
    public let maxHR: Double
    public let baseline: StressBaseline

    public init(profile: UserProfile, restingHR: Double?, maxHR: Double, baseline: StressBaseline) {
        self.profile = profile
        self.restingHR = restingHR
        self.maxHR = maxHR
        self.baseline = baseline
    }
}

public enum MinuteMetricsCalculator {
    /// HR_flex used when RHR is unknown. This is the floor of the PLAN.md 8.4 formula.
    static let fallbackHeartRateFlex = 90.0

    /// One row per UTC minute in `range`. `range` must be minute-aligned.
    ///
    /// HRV and stress come from the 5-minute window that contains the minute.
    /// Kcal comes from the minute's own hr_avg. A minute with no HR is charged BMR and marked estimated.
    /// `rr` must be accepted intervals in arrival order.
    public static func rows(
        range: Range<Int64>,
        samples: [HeartRateSample],
        rr: [RRSample],
        context: MinuteMetricsContext
    ) -> [MinuteMetric] {
        let minutes = Dictionary(
            uniqueKeysWithValues: MinuteAggregation.aggregate(samples).map { ($0.minuteMs, $0) }
        )
        let windowRange = LocalTime.roundDown(range.lowerBound, to: LocalTime.msPerWindow)
            ..< LocalTime.roundUp(range.upperBound, to: LocalTime.msPerWindow)
        var scores: [Int64: StressResult] = [:]
        var hrvByStart: [Int64: FiveMinuteWindow] = [:]
        for window in FiveMinuteWindows.build(samples: samples, rr: rr, range: windowRange) {
            hrvByStart[window.startMs] = window
            scores[window.startMs] = Stress.score(
                window: window,
                restingHR: context.restingHR,
                maxHR: context.maxHR,
                baseline: context.baseline
            )
        }

        let heartRateFlex = context.restingHR.map {
            Calories.heartRateFlex(restingHR: $0, maxHR: context.maxHR)
        } ?? fallbackHeartRateFlex

        let minuteStarts = LocalTime.starts(
            from: range.lowerBound,
            to: range.upperBound,
            step: LocalTime.msPerMinute
        )
        return minuteStarts.map { minuteMs in
            let minute = minutes[minuteMs]
            let windowStart = LocalTime.roundDown(minuteMs, to: LocalTime.msPerWindow)
            let window = hrvByStart[windowStart]
            let stress = scores[windowStart] ?? StressResult(stress: nil, state: .insufficient)
            let energy = Calories.minuteEnergy(
                heartRate: minute?.hrAvg,
                profile: context.profile,
                heartRateFlex: heartRateFlex
            )
            return MinuteMetric(
                minuteMs: minuteMs,
                hrAvg: minute?.hrAvg,
                hrMin: minute?.hrMin,
                hrMax: minute?.hrMax,
                hrN: minute?.hrN ?? 0,
                rmssdMs: window?.rmssd,
                sdnnMs: window?.sdnn,
                baevskySqrt: window?.baevskySqrt,
                stress: stress.stress,
                stressState: stress.state,
                kcal: energy.kcal,
                activeKcal: energy.activeKcal,
                kcalEstimated: energy.estimated,
                algoVersion: AlgoVersion.current
            )
        }
    }
}
