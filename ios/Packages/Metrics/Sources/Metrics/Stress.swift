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

public struct StressResult: Sendable, Equatable {
    /// Nil unless `state` is `.value` or `.hrOnly`.
    public let stress: Int?
    public let state: StressState

    public init(stress: Int?, state: StressState) {
        self.stress = stress
        self.state = state
    }
}

/// Personal baselines from the awake windows of the 14 local days before the scored day (PLAN.md 8.3).
///
/// A lookback day's baseline windows start inside that local day, outside its sleep and outside exertion.
/// Sleep is the main sleep that ended that morning and the one that began that evening (`SleepNights`).
/// A day with no detected sleep falls back to 00:00-06:00 local. A day qualifies with
/// `Stress.minAwakeWindowsPerDay` windows.
/// Two baselines exist. The R-R baseline uses valid windows and drives the value state.
/// The HR-only baseline uses every window with HR and drives the hr_only fallback.
public struct StressBaseline: Sendable, Equatable {
    /// Days in the lookback with at least `minAwakeWindowsPerDay` valid awake windows.
    public let validDays: Int
    public let hrMedian: Double?
    public let hrMAD: Double?
    public let lnRmssdMedian: Double?
    public let lnRmssdMAD: Double?
    /// Days in the lookback with at least `minAwakeWindowsPerDay` awake windows that have HR.
    public let hrOnlyDays: Int
    public let hrOnlyMedian: Double?
    public let hrOnlyMAD: Double?

    public init(
        validDays: Int,
        hrMedian: Double?,
        hrMAD: Double?,
        lnRmssdMedian: Double?,
        lnRmssdMAD: Double?,
        hrOnlyDays: Int,
        hrOnlyMedian: Double?,
        hrOnlyMAD: Double?
    ) {
        self.validDays = validDays
        self.hrMedian = hrMedian
        self.hrMAD = hrMAD
        self.lnRmssdMedian = lnRmssdMedian
        self.lnRmssdMAD = lnRmssdMAD
        self.hrOnlyDays = hrOnlyDays
        self.hrOnlyMedian = hrOnlyMedian
        self.hrOnlyMAD = hrOnlyMAD
    }

    /// Baseline for scoring windows on local `day`. The lookback is the 14 days before `day`.
    /// `day` itself is excluded, so a window is never scored against itself.
    public static func build(
        windows: [FiveMinuteWindow],
        day: LocalDay,
        nights: SleepNights,
        restingHR: Double?,
        maxHR: Double
    ) -> StressBaseline {
        var validDays = 0
        var hrOnlyDays = 0
        var rrHR: [Double] = []
        var rrLnRmssd: [Double] = []
        var hrOnlyHR: [Double] = []

        for lookback in Stress.baselineDays(
            windows, day: day, nights: nights, restingHR: restingHR, maxHR: maxHR
        ) {
            if lookback.valid.count >= Stress.minAwakeWindowsPerDay {
                validDays += 1
            }
            if lookback.withHR.count >= Stress.minAwakeWindowsPerDay {
                hrOnlyDays += 1
            }
            rrHR += lookback.valid.compactMap(\.hrMean)
            rrLnRmssd += lookback.valid.compactMap(\.lnRmssd)
            hrOnlyHR += lookback.withHR.compactMap(\.hrMean)
        }

        return StressBaseline(
            validDays: validDays,
            hrMedian: Statistics.median(rrHR),
            hrMAD: Statistics.mad(rrHR),
            lnRmssdMedian: Statistics.median(rrLnRmssd),
            lnRmssdMAD: Statistics.mad(rrLnRmssd),
            hrOnlyDays: hrOnlyDays,
            hrOnlyMedian: Statistics.median(hrOnlyHR),
            hrOnlyMAD: Statistics.mad(hrOnlyHR)
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
    /// Windows a day needs to qualify (`Stress.minAwakeWindowsPerDay`).
    public let requiredWindows: Int

    public var id: LocalDay { day }

    /// True when this day counts toward the R-R baseline.
    public var qualifiesForRR: Bool { validWindowCount >= requiredWindows }
    /// True when this day counts toward the HR-only baseline.
    public var qualifiesForHROnly: Bool { hrWindowCount >= requiredWindows }

    /// R-R windows still missing before this day would qualify.
    public var validWindowsNeeded: Int { max(0, requiredWindows - validWindowCount) }
    /// HR windows still missing before this day would qualify for the HR-only path.
    public var hrWindowsNeeded: Int { max(0, requiredWindows - hrWindowCount) }

    /// Minutes of additional valid 5-minute windows this day needs.
    public var validMinutesNeeded: Int { validWindowsNeeded * Int(LocalTime.msPerWindow / LocalTime.msPerMinute) }
    /// Minutes of additional HR windows this day needs for the HR-only path.
    public var hrMinutesNeeded: Int { hrWindowsNeeded * Int(LocalTime.msPerWindow / LocalTime.msPerMinute) }
}

/// How close the stress baseline is to ready (PLAN.md 8.3).
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
    /// A day qualifies with at least this many awake windows (2 h of 5-minute windows).
    public static let minAwakeWindowsPerDay = 24
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
                requiredWindows: minAwakeWindowsPerDay
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
    /// - Valid R-R window: value = round(100 * Phi(0.5 z_HR - 0.5 z_HRV + centerOffset)). Needs the R-R baseline.
    /// - No valid R-R: hr_only = round(100 * Phi(0.5 z_HR + centerOffset)). Needs the HR-only baseline.
    /// - Insufficient only when a needed input or baseline median is missing. Sigma floors cover a zero MAD.
    public static func score(
        window: FiveMinuteWindow,
        restingHR: Double?,
        maxHR: Double,
        baseline: StressBaseline
    ) -> StressResult {
        if HeartRateZones.isExertion(hr: window.hrMean, restingHR: restingHR, maxHR: maxHR) {
            return StressResult(stress: nil, state: .exertion)
        }

        if window.valid {
            guard baseline.validDays >= minQualifyingDays else {
                return StressResult(stress: nil, state: .calibrating)
            }
            guard let hr = window.hrMean, let lnRmssd = window.lnRmssd,
                  let hrMedian = baseline.hrMedian, let hrMAD = baseline.hrMAD,
                  let lnMedian = baseline.lnRmssdMedian, let lnMAD = baseline.lnRmssdMAD
            else {
                return StressResult(stress: nil, state: .insufficient)
            }
            let zHR = zScore(hr, median: hrMedian, sigma: sigma(mad: hrMAD, floor: hrSigmaFloor))
            let zHRV = zScore(lnRmssd, median: lnMedian, sigma: sigma(mad: lnMAD, floor: lnRmssdSigmaFloor))
            return StressResult(stress: scaled(0.5 * zHR - 0.5 * zHRV), state: .value)
        }

        guard baseline.hrOnlyDays >= minQualifyingDays else {
            return StressResult(stress: nil, state: .calibrating)
        }
        guard let hr = window.hrMean, let median = baseline.hrOnlyMedian, let mad = baseline.hrOnlyMAD
        else {
            return StressResult(stress: nil, state: .insufficient)
        }
        let z = zScore(hr, median: median, sigma: sigma(mad: mad, floor: hrSigmaFloor))
        return StressResult(stress: scaled(0.5 * z), state: .hrOnly)
    }

    /// Maps a raw score to 0-100 with the centre offset (PLAN.md 8.3).
    private static func scaled(_ raw: Double) -> Int {
        Int((100 * normalCDF(raw + centerOffset)).rounded())
    }
}
