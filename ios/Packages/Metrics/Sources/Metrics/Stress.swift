import Foundation

/// Stress state (PLAN.md 8.3). Raw values are the `stress_state` strings in PLAN.md 10.2.
public enum StressState: String, Sendable, Equatable, CaseIterable {
    case value
    case calibrating
    case exertion
    case insufficient
    case hrOnly = "hr_only"
}

/// Band for UI copy (PLAN.md 8.3): 0-33 low, 34-66 moderate, 67-100 high.
public enum StressBand: String, Sendable, Equatable, Hashable, CaseIterable {
    case low
    case moderate
    case high

    public static func of(stress: Int) -> StressBand {
        switch stress {
        case ...33: return .low
        case ...66: return .moderate
        default: return .high
        }
    }
}

/// Which awake baseline scored a window (stress algo v3). `.combined` is every awake window of the lookback. The
/// medicated and unmedicated baselines split those windows by stimulant state. They are used only when the caller
/// supplies stimulant windows and the matching baseline is ready for the window.
public enum StressBaselineContext: String, Sendable, Equatable, CaseIterable {
    case combined
    case medicated
    case unmedicated
}

public struct StressResult: Sendable, Equatable {
    /// Nil unless `state` is `.value` or `.hrOnly`.
    public let stress: Int?
    public let state: StressState
    /// The baseline that scored the window. `.combined` unless a stimulant split applied.
    public let baselineContext: StressBaselineContext

    public init(stress: Int?, state: StressState, baselineContext: StressBaselineContext = .combined) {
        self.stress = stress
        self.state = state
        self.baselineContext = baselineContext
    }
}

/// Personal baselines from the awake windows of the 14 local days before the scored day (PLAN.md 8.3).
///
/// A lookback day's baseline windows start inside that local day, outside its sleep and outside exertion.
/// Sleep is the main sleep that ended that morning and the one that began that evening (`SleepNights`).
/// A day with no detected sleep falls back to 00:00-06:00 local. A day qualifies for the R-R baseline with
/// `Stress.minAwakeRRWindowsPerDay` valid windows, and for the HR-only baseline with `Stress.minAwakeWindowsPerDay`.
/// Two baselines exist. The R-R baseline uses valid windows and drives the value state.
/// The HR-only baseline uses every window with HR and drives the hr_only fallback.
/// When stimulant windows are supplied, `contexts` holds a medicated and an unmedicated baseline built from the same
/// lookback. Each has its own thresholds (`Stress.minContextQualifyingDays` and the context window counts).
public struct StressBaseline: Sendable, Equatable {
    /// Days in the lookback with at least `minAwakeRRWindowsPerDay` valid awake windows.
    public let validDays: Int
    public let hrMedian: Double?
    public let hrMAD: Double?
    public let lnRmssdMedian: Double?
    public let lnRmssdMAD: Double?
    /// Days in the lookback with at least `minAwakeWindowsPerDay` awake windows that have HR.
    public let hrOnlyDays: Int
    public let hrOnlyMedian: Double?
    public let hrOnlyMAD: Double?
    /// Qualifying days a baseline needs before it is ready (`Stress.minQualifyingDays` for the combined baseline).
    public let requiredDays: Int
    /// The medicated and unmedicated baselines. Empty unless stimulant windows were supplied to `build`.
    public let contexts: [StressBaselineContext: StressBaseline]

    public init(
        validDays: Int,
        hrMedian: Double?,
        hrMAD: Double?,
        lnRmssdMedian: Double?,
        lnRmssdMAD: Double?,
        hrOnlyDays: Int,
        hrOnlyMedian: Double?,
        hrOnlyMAD: Double?,
        requiredDays: Int = Stress.minQualifyingDays,
        contexts: [StressBaselineContext: StressBaseline] = [:]
    ) {
        self.validDays = validDays
        self.hrMedian = hrMedian
        self.hrMAD = hrMAD
        self.lnRmssdMedian = lnRmssdMedian
        self.lnRmssdMAD = lnRmssdMAD
        self.hrOnlyDays = hrOnlyDays
        self.hrOnlyMedian = hrOnlyMedian
        self.hrOnlyMAD = hrOnlyMAD
        self.requiredDays = requiredDays
        self.contexts = contexts
    }

    /// The baseline for `context`: this one for `.combined`, else the matching entry of `contexts`.
    public func context(_ context: StressBaselineContext) -> StressBaseline? {
        context == .combined ? self : contexts[context]
    }

    /// The R-R baseline has enough qualifying days and every median the value state needs.
    var isRRReady: Bool {
        validDays >= requiredDays && hrMedian != nil && hrMAD != nil && lnRmssdMedian != nil && lnRmssdMAD != nil
    }

    /// The HR-only baseline has enough qualifying days and its median and MAD.
    var isHROnlyReady: Bool {
        hrOnlyDays >= requiredDays && hrOnlyMedian != nil && hrOnlyMAD != nil
    }

    /// True when this baseline can score `window` on one of its paths. A context baseline that cannot is skipped
    /// in favour of the combined baseline.
    func canScore(_ window: FiveMinuteWindow) -> Bool {
        guard window.hrMean != nil else { return false }
        return (window.valid && isRRReady && window.lnRmssd != nil) || isHROnlyReady
    }

    /// Baseline for scoring windows on local `day`. The lookback is the 14 days before `day`.
    /// `day` itself is excluded, so a window is never scored against itself.
    ///
    /// With `stimulantWindows`, the same lookback also yields a medicated baseline (windows that start inside a
    /// stimulant window) and an unmedicated one (the rest). Without them, `contexts` stays empty and the result is
    /// the combined baseline alone.
    public static func build(
        windows: [FiveMinuteWindow],
        day: LocalDay,
        nights: SleepNights,
        restingHR: Double?,
        maxHR: Double,
        stimulantWindows: [MedicationWindow] = []
    ) -> StressBaseline {
        var combined = BaselineAccumulator()
        var medicated = BaselineAccumulator()
        var unmedicated = BaselineAccumulator()
        let split = !stimulantWindows.isEmpty
        let isMedicated = { (window: FiveMinuteWindow) in
            MedicationEffect.isStimulantActive(at: window.startMs, windows: stimulantWindows)
        }

        for lookback in Stress.baselineDays(
            windows, day: day, nights: nights, restingHR: restingHR, maxHR: maxHR
        ) {
            combined.add(valid: lookback.valid, withHR: lookback.withHR, thresholds: .combined)
            guard split else { continue }
            medicated.add(
                valid: lookback.valid.filter(isMedicated),
                withHR: lookback.withHR.filter(isMedicated),
                thresholds: .context
            )
            unmedicated.add(
                valid: lookback.valid.filter { !isMedicated($0) },
                withHR: lookback.withHR.filter { !isMedicated($0) },
                thresholds: .context
            )
        }

        var contexts: [StressBaselineContext: StressBaseline] = [:]
        if split {
            contexts[.medicated] = medicated.baseline(thresholds: .context)
            contexts[.unmedicated] = unmedicated.baseline(thresholds: .context)
        }
        return combined.baseline(thresholds: .combined, contexts: contexts)
    }
}

/// Thresholds for one baseline: windows a day needs on each path, and the qualifying days the baseline needs.
private struct BaselineThresholds {
    let rrWindowsPerDay: Int
    let hrWindowsPerDay: Int
    let requiredDays: Int

    static let combined = BaselineThresholds(
        rrWindowsPerDay: Stress.minAwakeRRWindowsPerDay,
        hrWindowsPerDay: Stress.minAwakeWindowsPerDay,
        requiredDays: Stress.minQualifyingDays
    )
    static let context = BaselineThresholds(
        rrWindowsPerDay: Stress.minContextRRWindowsPerDay,
        hrWindowsPerDay: Stress.minContextAwakeWindowsPerDay,
        requiredDays: Stress.minContextQualifyingDays
    )
}

/// Collects the lookback days of one baseline, then produces its medians and MADs.
private struct BaselineAccumulator {
    var validDays = 0
    var hrOnlyDays = 0
    var rrHR: [Double] = []
    var rrLnRmssd: [Double] = []
    var hrOnlyHR: [Double] = []

    mutating func add(valid: [FiveMinuteWindow], withHR: [FiveMinuteWindow], thresholds: BaselineThresholds) {
        if valid.count >= thresholds.rrWindowsPerDay {
            validDays += 1
        }
        if withHR.count >= thresholds.hrWindowsPerDay {
            hrOnlyDays += 1
        }
        rrHR += valid.compactMap(\.hrMean)
        rrLnRmssd += valid.compactMap(\.lnRmssd)
        hrOnlyHR += withHR.compactMap(\.hrMean)
    }

    func baseline(
        thresholds: BaselineThresholds,
        contexts: [StressBaselineContext: StressBaseline] = [:]
    ) -> StressBaseline {
        StressBaseline(
            validDays: validDays,
            hrMedian: Statistics.median(rrHR),
            hrMAD: Statistics.mad(rrHR),
            lnRmssdMedian: Statistics.median(rrLnRmssd),
            lnRmssdMAD: Statistics.mad(rrLnRmssd),
            hrOnlyDays: hrOnlyDays,
            hrOnlyMedian: Statistics.median(hrOnlyHR),
            hrOnlyMAD: Statistics.mad(hrOnlyHR),
            requiredDays: thresholds.requiredDays,
            contexts: contexts
        )
    }
}

/// One lookback day in the stress baseline, as seen by `Stress.calibrationProgress`.
public struct StressDayProgress: Sendable, Equatable, Identifiable {
    /// The local day whose awake windows are counted.
    public let day: LocalDay
    /// Days before the scored day this one is. 1 is the day immediately before it.
    public let offset: Int
    /// Awake windows that pass the R-R validity rule, after exertion is excluded.
    public let validWindowCount: Int
    /// Awake windows with a heart-rate mean, after exertion is excluded.
    public let hrWindowCount: Int
    /// Valid windows a day needs for the R-R baseline (`Stress.minAwakeRRWindowsPerDay`).
    public let requiredWindows: Int
    /// Windows with HR a day needs for the HR-only baseline (`Stress.minAwakeWindowsPerDay`).
    public let requiredHRWindows: Int

    public var id: LocalDay { day }

    /// True when this day counts toward the R-R baseline.
    public var qualifiesForRR: Bool { validWindowCount >= requiredWindows }
    /// True when this day counts toward the HR-only baseline.
    public var qualifiesForHROnly: Bool { hrWindowCount >= requiredHRWindows }

    /// R-R windows still missing before this day would qualify.
    public var validWindowsNeeded: Int { max(0, requiredWindows - validWindowCount) }
    /// HR windows still missing before this day would qualify for the HR-only path.
    public var hrWindowsNeeded: Int { max(0, requiredHRWindows - hrWindowCount) }

    /// Minutes of additional valid 5-minute windows this day needs.
    public var validMinutesNeeded: Int { validWindowsNeeded * Int(LocalTime.msPerWindow / LocalTime.msPerMinute) }
    /// Minutes of additional HR windows this day needs for the HR-only path.
    public var hrMinutesNeeded: Int { hrWindowsNeeded * Int(LocalTime.msPerWindow / LocalTime.msPerMinute) }
}

/// How close the stress baseline is to ready (PLAN.md 8.3). Always the combined baseline, never a stimulant context.
public struct StressCalibrationProgress: Sendable, Equatable {
    /// Days that qualify for the R-R baseline, same count as `StressBaseline.validDays`.
    public let qualifyingDays: Int
    /// Days needed before values replace the calibrating state (7 at the time of writing).
    public let requiredDays: Int
    /// Days inspected before the scored day (14 at the time of writing).
    public let lookbackDays: Int
    /// Days that qualify for the HR-only baseline. Days with valid R-R also count here.
    public let hrOnlyDays: Int
    /// Most recent day first: offsets 1 through `lookbackDays`.
    public let days: [StressDayProgress]

    /// The R-R baseline is ready.
    public var isCalibrated: Bool { qualifyingDays >= requiredDays }
    /// R-R-qualifying days still missing, assuming no existing day gains windows.
    public var daysNeeded: Int { max(0, requiredDays - qualifyingDays) }

    /// The HR-only baseline is ready.
    public var isHROnlyCalibrated: Bool { hrOnlyDays >= requiredDays }
    /// HR-only-qualifying days still missing.
    public var hrOnlyDaysNeeded: Int { max(0, requiredDays - hrOnlyDays) }

    /// The most recent lookback day's detail, if the lookback was built.
    public var latestDay: StressDayProgress? { days.first }

    /// Returned when the profile cannot supply HRmax, so the baseline cannot be built at all.
    public static let unavailable = StressCalibrationProgress(
        qualifyingDays: 0,
        requiredDays: Stress.minQualifyingDays,
        lookbackDays: Stress.lookbackDays,
        hrOnlyDays: 0,
        days: []
    )
}

public enum Stress {
    /// Scale that makes MAD a consistent sigma estimate for normal data.
    public static let madScale = 1.4826
    /// Calibration: at least this many qualifying days (PLAN.md 8.3).
    public static let minQualifyingDays = 7
    /// A day qualifies for the R-R baseline with at least this many valid awake windows (1 h of 5-minute windows).
    public static let minAwakeRRWindowsPerDay = 12
    /// A day qualifies for the HR-only baseline with at least this many awake windows that have HR (2 h).
    public static let minAwakeWindowsPerDay = 24
    /// Medicated and unmedicated baselines (stimulant split): qualifying days needed, and windows per day on each path.
    public static let minContextQualifyingDays = 5
    public static let minContextRRWindowsPerDay = 6
    public static let minContextAwakeWindowsPerDay = 12
    public static let lookbackDays = 14
    /// Floor on the HR sigma, in bpm. A steady baseline has MAD 0, which would make any deviation infinitely
    /// large. The floor keeps a few bpm of deviation from scoring as a full sigma.
    public static let hrSigmaFloor = 4.0
    /// Floor on the ln(RMSSD) sigma (about 16 % of RMSSD), for the same reason as `hrSigmaFloor`.
    public static let lnRmssdSigmaFloor = 0.15
    /// Shifts the scale so the median awake window scores about 33, the top of Low (PLAN.md 8.3).
    /// Raw scores are z-based, so a raw score of 0 is the baseline median. Phi(-0.44) is about 0.33.
    public static let centerOffset = -0.44

    /// The baseline windows of each lookback day, most recent first.
    ///
    /// This is the one place the awake-window and exertion rules live. `StressBaseline.build` and
    /// `calibrationProgress` both use it, so progress can never disagree with scoring.
    struct DayWindows {
        let day: LocalDay
        let offset: Int
        /// Windows that pass the R-R validity rule.
        let valid: [FiveMinuteWindow]
        /// Windows with a heart-rate mean, including invalid R-R windows.
        let withHR: [FiveMinuteWindow]
    }

    static func baselineDays(
        _ windows: [FiveMinuteWindow],
        day: LocalDay,
        nights: SleepNights,
        restingHR: Double?,
        maxHR: Double
    ) -> [DayWindows] {
        let zone = nights.timeZone
        return (1...lookbackDays).map { offset in
            let lookbackDay = LocalTime.adding(days: -offset, to: day)
            let dayStart = LocalTime.localTime(lookbackDay, hour: 0, in: zone)
            let dayEnd = LocalTime.localTime(LocalTime.adding(days: 1, to: lookbackDay), hour: 0, in: zone)
            // Sleep that touches this day: the night that ends on it (the morning) and the night that ends
            // the next morning (it began this evening). Both are excluded.
            let sleep = [
                nights.window(of: lookbackDay),
                nights.window(of: LocalTime.adding(days: 1, to: lookbackDay)),
            ]
            let eligible = windows.filter { window in
                window.startMs >= dayStart
                    && window.startMs < dayEnd
                    && !sleep.contains { $0.contains(window.startMs) }
                    && !HeartRateZones.isExertion(hr: window.hrMean, restingHR: restingHR, maxHR: maxHR)
            }
            return DayWindows(
                day: lookbackDay,
                offset: offset,
                valid: eligible.filter(\.valid),
                withHR: eligible.filter { $0.hrMean != nil }
            )
        }
    }

    /// How close `windows` are to a ready baseline for `day`. Uses the same rules as `StressBaseline.build`,
    /// so `qualifyingDays` matches `StressBaseline.validDays` and `hrOnlyDays` matches its HR-only count.
    public static func calibrationProgress(
        windows: [FiveMinuteWindow],
        day: LocalDay,
        nights: SleepNights,
        restingHR: Double?,
        maxHR: Double
    ) -> StressCalibrationProgress {
        let lookback = baselineDays(
            windows, day: day, nights: nights, restingHR: restingHR, maxHR: maxHR
        ).map { lookbackDay in
            StressDayProgress(
                day: lookbackDay.day,
                offset: lookbackDay.offset,
                validWindowCount: lookbackDay.valid.count,
                hrWindowCount: lookbackDay.withHR.count,
                requiredWindows: minAwakeRRWindowsPerDay,
                requiredHRWindows: minAwakeWindowsPerDay
            )
        }
        return StressCalibrationProgress(
            qualifyingDays: lookback.filter(\.qualifiesForRR).count,
            requiredDays: minQualifyingDays,
            lookbackDays: lookbackDays,
            hrOnlyDays: lookback.filter(\.qualifiesForHROnly).count,
            days: lookback
        )
    }

    /// Standard normal CDF, via erfc.
    public static func normalCDF(_ z: Double) -> Double {
        0.5 * erfc(-z / 2.0.squareRoot())
    }

    /// The sigma for a z-score: the scaled MAD, but never below `floor`.
    public static func sigma(mad: Double, floor: Double) -> Double {
        max(madScale * mad, floor)
    }

    /// Robust z-score against a sigma from `sigma(mad:floor:)`.
    public static func zScore(_ value: Double, median: Double, sigma: Double) -> Double {
        (value - median) / sigma
    }

    /// Scores one window (PLAN.md 8.3). Precedence: exertion, then calibrating, then insufficient.
    ///
    /// - Valid R-R window with a ready R-R baseline: value = round(100 * Phi(0.5 z_HR - 0.5 z_HRV + centerOffset)).
    /// - Otherwise, when the HR-only baseline is ready: hr_only = round(100 * Phi(0.5 z_HR + centerOffset)).
    ///   A valid window whose R-R baseline is not ready is scored here, so it is not left calibrating.
    /// - Calibrating only when the path the window needs has too few qualifying days.
    /// - Insufficient only when a needed input or baseline median is missing. Sigma floors cover a zero MAD.
    ///
    /// With `stimulantWindows`, a window that starts inside a stimulant window is scored against the medicated
    /// baseline, and any other window against the unmedicated one. If that context baseline cannot score the
    /// window, the combined `baseline` is used instead.
    public static func score(
        window: FiveMinuteWindow,
        restingHR: Double?,
        maxHR: Double,
        baseline: StressBaseline,
        stimulantWindows: [MedicationWindow] = []
    ) -> StressResult {
        if HeartRateZones.isExertion(hr: window.hrMean, restingHR: restingHR, maxHR: maxHR) {
            return StressResult(stress: nil, state: .exertion)
        }
        let (used, context) = baselineFor(window, baseline: baseline, stimulantWindows: stimulantWindows)
        let scored = scoreAgainst(window, used)
        return StressResult(stress: scored.stress, state: scored.state, baselineContext: context)
    }

    /// The baseline that scores `window`, and its context. The combined baseline unless a stimulant split applies.
    private static func baselineFor(
        _ window: FiveMinuteWindow,
        baseline: StressBaseline,
        stimulantWindows: [MedicationWindow]
    ) -> (StressBaseline, StressBaselineContext) {
        guard !stimulantWindows.isEmpty else { return (baseline, .combined) }
        let context: StressBaselineContext = MedicationEffect.isStimulantActive(
            at: window.startMs, windows: stimulantWindows
        ) ? .medicated : .unmedicated
        guard let candidate = baseline.context(context), candidate.canScore(window) else {
            return (baseline, .combined)
        }
        return (candidate, context)
    }

    /// The value, hr_only, calibrating or insufficient result for `window` against one baseline.
    private static func scoreAgainst(
        _ window: FiveMinuteWindow,
        _ baseline: StressBaseline
    ) -> (stress: Int?, state: StressState) {
        if window.valid, baseline.isRRReady {
            guard let hr = window.hrMean, let lnRmssd = window.lnRmssd,
                  let hrMedian = baseline.hrMedian, let hrMAD = baseline.hrMAD,
                  let lnMedian = baseline.lnRmssdMedian, let lnMAD = baseline.lnRmssdMAD
            else {
                return (nil, .insufficient)
            }
            let zHR = zScore(hr, median: hrMedian, sigma: sigma(mad: hrMAD, floor: hrSigmaFloor))
            let zHRV = zScore(lnRmssd, median: lnMedian, sigma: sigma(mad: lnMAD, floor: lnRmssdSigmaFloor))
            return (scaled(0.5 * zHR - 0.5 * zHRV), .value)
        }

        // No valid R-R window, or the R-R baseline is not ready: the HR-only path.
        guard baseline.hrOnlyDays >= baseline.requiredDays else {
            return (nil, .calibrating)
        }
        guard let hr = window.hrMean, let median = baseline.hrOnlyMedian, let mad = baseline.hrOnlyMAD
        else {
            return (nil, .insufficient)
        }
        let z = zScore(hr, median: median, sigma: sigma(mad: mad, floor: hrSigmaFloor))
        return (scaled(0.5 * z), .hrOnly)
    }

    /// Maps a raw score to 0-100 with the centre offset (PLAN.md 8.3).
    private static func scaled(_ raw: Double) -> Int {
        Int((100 * normalCDF(raw + centerOffset)).rounded())
    }
}
