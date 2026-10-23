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

/// Personal baselines from the 14 local days before the scored day (PLAN.md 8.3).
///
/// Night windows are those starting inside each lookback day's night: its main sleep when one was
/// detected (`SleepNights`), else 00:00–06:00 local. Windows in exertion are excluded.
/// Two baselines exist. The R-R baseline uses valid windows and drives the value state.
/// The HR-only baseline uses every window with HR and drives the hr_only fallback.
public struct StressBaseline: Sendable, Equatable {
    /// Days in the lookback with at least 12 valid night windows.
    public let validDays: Int
    public let hrMedian: Double?
    public let hrMAD: Double?
    public let lnRmssdMedian: Double?
    public let lnRmssdMAD: Double?
    /// Days in the lookback with at least 12 night windows that have HR.
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
    /// `day`'s own night is excluded, so a window is never scored against itself.
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

        for night in Stress.nightWindows(
            windows, day: day, nights: nights, restingHR: restingHR, maxHR: maxHR
        ) {
            if night.valid.count >= Stress.minNightWindowsPerDay {
                validDays += 1
            }
            if night.withHR.count >= Stress.minNightWindowsPerDay {
                hrOnlyDays += 1
            }
            rrHR += night.valid.compactMap(\.hrMean)
            rrLnRmssd += night.valid.compactMap(\.lnRmssd)
            hrOnlyHR += night.withHR.compactMap(\.hrMean)
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

/// One night in the stress baseline lookback, as seen by `Stress.calibrationProgress`.
public struct StressNightProgress: Sendable, Equatable, Identifiable {
    /// Local day whose night is counted (the main sleep that ended that day, else 00:00-06:00 local).
    public let day: LocalDay
    /// Nights before the scored day this night is. 1 is the night immediately before it.
    public let offset: Int
    /// Windows that pass the R-R validity rule, after exertion is excluded.
    public let validWindowCount: Int
    /// Windows with a heart-rate mean, after exertion is excluded.
    public let hrWindowCount: Int
    /// Windows a day needs to qualify (12 at the time of writing).
    public let requiredWindows: Int

    public var id: LocalDay { day }

    /// True when this night counts toward the R-R baseline.
    public var qualifiesForRR: Bool { validWindowCount >= requiredWindows }
    /// True when this night counts toward the HR-only baseline.
    public var qualifiesForHROnly: Bool { hrWindowCount >= requiredWindows }

    /// R-R windows still missing before this night would qualify.
    public var validWindowsNeeded: Int { max(0, requiredWindows - validWindowCount) }
    /// HR windows still missing before this night would qualify for the HR-only path.
    public var hrWindowsNeeded: Int { max(0, requiredWindows - hrWindowCount) }

    /// Minutes of additional valid 5-minute windows this night needs.
    public var validMinutesNeeded: Int { validWindowsNeeded * Int(LocalTime.msPerWindow / LocalTime.msPerMinute) }
    /// Minutes of additional HR windows this night needs for the HR-only path.
    public var hrMinutesNeeded: Int { hrWindowsNeeded * Int(LocalTime.msPerWindow / LocalTime.msPerMinute) }
}

/// How close the stress baseline is to ready (PLAN.md 8.3).
public struct StressCalibrationProgress: Sendable, Equatable {
    /// Days that qualify for the R-R baseline, same count as `StressBaseline.validDays`.
    public let qualifyingDays: Int
    /// Days needed before values replace the calibrating state (7 at the time of writing).
    public let requiredDays: Int
    /// Nights inspected before the scored day (14 at the time of writing).
    public let lookbackDays: Int
    /// Days that qualify for the HR-only baseline. Days with valid R-R also count here.
    public let hrOnlyDays: Int
    /// Most recent night first: offsets 1 through `lookbackDays`.
    public let nights: [StressNightProgress]

    /// The R-R baseline is ready.
    public var isCalibrated: Bool { qualifyingDays >= requiredDays }
    /// R-R-qualifying nights still missing, assuming no existing night gains windows.
    public var daysNeeded: Int { max(0, requiredDays - qualifyingDays) }

    /// The HR-only baseline is ready.
    public var isHROnlyCalibrated: Bool { hrOnlyDays >= requiredDays }
    /// HR-only-qualifying nights still missing.
    public var hrOnlyDaysNeeded: Int { max(0, requiredDays - hrOnlyDays) }

    /// The most recent night's detail, if the lookback was built.
    public var latestNight: StressNightProgress? { nights.first }

    /// Returned when the profile cannot supply HRmax, so the baseline cannot be built at all.
    public static let unavailable = StressCalibrationProgress(
        qualifyingDays: 0,
        requiredDays: Stress.minQualifyingDays,
        lookbackDays: Stress.lookbackDays,
        hrOnlyDays: 0,
        nights: []
    )
}

public enum Stress {
    /// Scale that makes MAD a consistent sigma estimate for normal data.
    public static let madScale = 1.4826
    /// Calibration: at least this many qualifying days (PLAN.md 8.3).
    public static let minQualifyingDays = 7
    /// A day qualifies with at least this many night windows.
    public static let minNightWindowsPerDay = 12
    public static let lookbackDays = 14

    /// The eligible windows for each night in the baseline lookback, most recent first.
    ///
    /// This is the one place the night-window and exertion rules live. `StressBaseline.build` and
    /// `calibrationProgress` both use it, so progress can never disagree with scoring.
    struct NightWindows {
        let day: LocalDay
        let offset: Int
        /// Windows that pass the R-R validity rule.
        let valid: [FiveMinuteWindow]
        /// Windows with a heart-rate mean, including invalid R-R windows.
        let withHR: [FiveMinuteWindow]
    }

    static func nightWindows(
        _ windows: [FiveMinuteWindow],
        day: LocalDay,
        nights: SleepNights,
        restingHR: Double?,
        maxHR: Double
    ) -> [NightWindows] {
        (1...lookbackDays).map { offset in
            let nightDay = LocalTime.adding(days: -offset, to: day)
            let night = nights.window(of: nightDay)
            let eligible = windows.filter {
                night.contains($0.startMs)
                    && !HeartRateZones.isExertion(hr: $0.hrMean, restingHR: restingHR, maxHR: maxHR)
            }
            return NightWindows(
                day: nightDay,
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
        let lookback = nightWindows(
            windows, day: day, nights: nights, restingHR: restingHR, maxHR: maxHR
        ).map { night in
            StressNightProgress(
                day: night.day,
                offset: night.offset,
                validWindowCount: night.valid.count,
                hrWindowCount: night.withHR.count,
                requiredWindows: minNightWindowsPerDay
            )
        }
        return StressCalibrationProgress(
            qualifyingDays: lookback.filter(\.qualifiesForRR).count,
            requiredDays: minQualifyingDays,
            lookbackDays: lookbackDays,
            hrOnlyDays: lookback.filter(\.qualifiesForHROnly).count,
            nights: lookback
        )
    }

    /// Standard normal CDF, via erfc.
    public static func normalCDF(_ z: Double) -> Double {
        0.5 * erfc(-z / 2.0.squareRoot())
    }

    /// Robust z-score. The caller must check that `mad` is positive.
    public static func zScore(_ value: Double, median: Double, mad: Double) -> Double {
        (value - median) / (madScale * mad)
    }

    /// Scores one window (PLAN.md 8.3). Precedence: exertion, then calibrating, then insufficient.
    ///
    /// - Valid R-R window: value = round(100 * Phi(0.5 z_HR - 0.5 z_HRV)). Needs the R-R baseline.
    /// - No valid R-R: hr_only = round(100 * Phi(z_HR)). Needs the HR-only baseline.
    /// - A zero MAD in a needed component is insufficient. The components are not dropped silently.
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
                  let hrMedian = baseline.hrMedian, let hrMAD = baseline.hrMAD, hrMAD > 0,
                  let lnMedian = baseline.lnRmssdMedian, let lnMAD = baseline.lnRmssdMAD, lnMAD > 0
            else {
                return StressResult(stress: nil, state: .insufficient)
            }
            let zHR = zScore(hr, median: hrMedian, mad: hrMAD)
            let zHRV = zScore(lnRmssd, median: lnMedian, mad: lnMAD)
            return StressResult(stress: scaled(0.5 * zHR - 0.5 * zHRV), state: .value)
        }

        guard baseline.hrOnlyDays >= minQualifyingDays else {
            return StressResult(stress: nil, state: .calibrating)
        }
        guard let hr = window.hrMean,
              let median = baseline.hrOnlyMedian, let mad = baseline.hrOnlyMAD, mad > 0
        else {
            return StressResult(stress: nil, state: .insufficient)
        }
        return StressResult(stress: scaled(zScore(hr, median: median, mad: mad)), state: .hrOnly)
    }

    private static func scaled(_ raw: Double) -> Int {
        Int((100 * normalCDF(raw)).rounded())
    }
}
