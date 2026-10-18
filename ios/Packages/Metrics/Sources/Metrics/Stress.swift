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
public enum StressBand: String, Sendable, Equatable {
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
/// Night windows are those starting in [00:00, 06:00) local. Windows in exertion are excluded.
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
        in timeZone: TimeZone,
        restingHR: Double?,
        maxHR: Double
    ) -> StressBaseline {
        var validDays = 0
        var hrOnlyDays = 0
        var rrHR: [Double] = []
        var rrLnRmssd: [Double] = []
        var hrOnlyHR: [Double] = []

        for offset in 1...Stress.lookbackDays {
            let night = LocalTime.nightWindow(
                of: LocalTime.adding(days: -offset, to: day),
                in: timeZone
            )
            let nightWindows = windows.filter {
                night.contains($0.startMs)
                    && !HeartRateZones.isExertion(hr: $0.hrMean, restingHR: restingHR, maxHR: maxHR)
            }
            let validNights = nightWindows.filter(\.valid)
            if validNights.count >= Stress.minNightWindowsPerDay {
                validDays += 1
            }
            let hrNights = nightWindows.compactMap(\.hrMean)
            if hrNights.count >= Stress.minNightWindowsPerDay {
                hrOnlyDays += 1
            }
            rrHR += validNights.compactMap(\.hrMean)
            rrLnRmssd += validNights.compactMap(\.lnRmssd)
            hrOnlyHR += hrNights
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

public enum Stress {
    /// Scale that makes MAD a consistent sigma estimate for normal data.
    public static let madScale = 1.4826
    /// Calibration: at least this many qualifying days (PLAN.md 8.3).
    public static let minQualifyingDays = 7
    /// A day qualifies with at least this many night windows.
    public static let minNightWindowsPerDay = 12
    public static let lookbackDays = 14

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
