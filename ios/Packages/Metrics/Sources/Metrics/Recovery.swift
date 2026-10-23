import Foundation

// Recovery.swift: nightly recovery score (0-100), colour band, and the personal baselines behind it.
//
// Ported from NOOP's StrandAnalytics package (read-only reference, Swift):
//   - RecoveryScorer.recovery(...)   Packages/StrandAnalytics/Sources/StrandAnalytics/RecoveryScorer.swift
//     (weights, z-score form, logistic, band cut-offs, sleep-performance centre/scale)
//   - Baselines.update / foldHistory  .../StrandAnalytics/Baselines.swift
//     (winsorised EWMA centre, EWMA absolute-deviation spread, cold-start and stale gates, metricCfg)
// NOOP's header says it was ported from server/ingest/app/analysis/recovery.py. That file was not
// part of the reference checkout, so the port is taken from the Swift source as it stands.
//
// APPROXIMATE. This is a labelled proxy, not WHOOP's Recovery score. WHOOP's model is proprietary and
// NOOP says so in its own header. The proxy is transparent and HRV-dominant, and it normalises each
// driver against the user's own baseline:
//   higher HRV vs baseline          -> higher recovery   (wHRV = 0.55, dominant)
//   lower resting HR vs baseline    -> higher recovery   (wRHR = 0.20)
//   higher sleep performance        -> higher recovery   (wSleep = 0.15, no baseline needed)
//   lower respiratory rate vs base  -> higher recovery   (wResp = 0.05)
//
// Deliberately NOT ported from NOOP, because the inputs were out of scope for this API:
//   skin-temperature deviation (wSkinTemp 0.05), overnight HR-decline slope (wRecoveryIndex 0.05),
//   previous-day Effort balance (wActivityBalance 0.05), and the parasympathetic-saturation guard
//   (detected but not applied in NOOP either). Adding one later is a new optional input, and the
//   remaining weights renormalise the same way.
//
// Baseline history must be STRICTLY PRIOR nights: do not include tonight. Including tonight pulls the
// baseline toward the value being judged and understates how unusual the night is.

public enum Recovery {

    // MARK: - Constants

    /// Valid nights before the HRV baseline is usable. NOOP `Baselines.minNightsSeed` = 4.
    /// Below this the score is withheld (`Outcome.insufficientBaseline`). It is not guessed.
    public static let minNightsSeed = 4
    /// Valid nights before NOOP calls a baseline "trusted" (`Baselines.minNightsTrust` = 14).
    /// The score is still produced between 4 and 13 nights, flagged as provisional by `baseline.status`.
    public static let minNightsTrust = 14

    /// Composite weights, NOOP `RecoveryScorer` (wHRV, wRHR, wSleep, wResp). Renormalised over the
    /// drivers that are present, so a missing driver is dropped and never zero-imputed.
    static let wHRV: Double = 0.55
    static let wRHR: Double = 0.20
    static let wSleep: Double = 0.15
    static let wResp: Double = 0.05

    /// Sleep-performance centre and scale, NOOP `RecoveryScorer.sleepPerfCenter` (0.85, "good night"
    /// at about 85 % efficiency) and `sleepPerfScale` (0.12). The z is (sp - 0.85) / 0.12.
    static let sleepPerfCenter: Double = 0.85
    static let sleepPerfScale: Double = 0.12

    /// Logistic spread and offset, NOOP `RecoveryScorer.logisticK` = 1.6 and `logisticZ0` = -0.20.
    /// The offset places a composite z of 0 at about 58 %, WHOOP's published population mean.
    static let logisticK: Double = 1.6
    static let logisticZ0: Double = -0.20

    /// Band cut-offs, NOOP `RecoveryScorer.bandRedMax` = 34 and `bandYellowMax` = 67.
    /// Red is below 34, yellow is 34 up to 67, green is 67 and above.
    static let bandRedMax: Double = 34
    static let bandYellowMax: Double = 67

    /// Robust-z denominator factor, NOOP `RecoveryScorer.zScore`: sigma = 1.253 x EWMA spread, which
    /// approximates a Gaussian sigma from an absolute-deviation tracker.
    static let sigmaFactor: Double = 1.253

    // MARK: - Public types

    /// Red, yellow or green, from `Recovery.band(for:)`.
    public enum Band: String, Sendable, Equatable {
        case red
        case yellow
        case green
    }

    /// A scored input. Each case is a term in the weighted composite.
    public enum Driver: String, Sendable, Equatable, CaseIterable {
        case hrv
        case restingHR
        case respiratoryRate
        case sleep
    }

    /// Baseline state from the EWMA fold. This is the user's own norm for one driver.
    public struct Baseline: Sendable, Equatable {
        /// Robust EWMA centre, the personal "mean".
        public let center: Double
        /// EWMA of absolute deviations, floored at the driver's floor spread. Times 1.253 gives sigma.
        public let spread: Double
        /// Valid nights folded into the baseline.
        public let nValid: Int
        public let status: BaselineStatus

        /// True when at least provisionally usable (`status` is provisional or trusted).
        public var usable: Bool { status == .provisional || status == .trusted }
    }

    /// NOOP `BaselineStatus`, mirrored here so the Metrics package stays self-contained.
    public enum BaselineStatus: String, Sendable, Equatable {
        /// Fewer than `minNightsSeed` valid nights.
        case calibrating
        /// Usable, between `minNightsSeed` and `minNightsTrust - 1` valid nights.
        case provisional
        /// At least `minNightsTrust` valid nights.
        case trusted
        /// Usable, but no valid night for more than 14 nights in a row.
        case stale
    }

    /// One driver's share of the composite.
    public struct Contribution: Sendable, Equatable {
        public let driver: Driver
        /// Share of the composite weight after renormalising over the drivers present. All shares sum to 1.
        public let weight: Double
        /// Driver z-score. Positive means good for recovery.
        public let zScore: Double

        /// `weight * zScore`. The composite z is the sum of these.
        public var weightedZ: Double { weight * zScore }
    }

    /// A tonight's inputs and the user's prior-night histories.
    public struct Input: Sendable, Equatable {
        /// Tonight's nightly RMSSD in ms (`HRV.rmssd`).
        public let hrv: Double
        /// Tonight's nightly resting HR in bpm (`RestingHR.forNight`).
        public let restingHR: Double
        /// Tonight's respiratory rate in breaths/min. Optional. Nil drops the term.
        public let respiratoryRate: Double?
        /// Tonight's sleep performance as a fraction in 0...1. Optional. Nil drops the term.
        public let sleepPerformance: Double?
        /// Prior nights' RMSSD, oldest first. A nil entry is a missing night. Excludes tonight.
        public let hrvHistory: [Double?]
        /// Prior nights' resting HR, oldest first. A nil entry is a missing night. Excludes tonight.
        public let restingHRHistory: [Double?]
        /// Prior nights' respiratory rate, oldest first. A nil entry is a missing night. Excludes tonight.
        public let respiratoryRateHistory: [Double?]

        public init(hrv: Double,
                    restingHR: Double,
                    respiratoryRate: Double? = nil,
                    sleepPerformance: Double? = nil,
                    hrvHistory: [Double?],
                    restingHRHistory: [Double?] = [],
                    respiratoryRateHistory: [Double?] = []) {
            self.hrv = hrv
            self.restingHR = restingHR
            self.respiratoryRate = respiratoryRate
            self.sleepPerformance = sleepPerformance
            self.hrvHistory = hrvHistory
            self.restingHRHistory = restingHRHistory
            self.respiratoryRateHistory = respiratoryRateHistory
        }
    }

    /// A produced score with the reasoning behind it.
    public struct Score: Sendable, Equatable {
        /// Recovery on 0...100, clamped. A logistic of the composite z (NOOP `logisticScore`).
        public let score: Double
        public let band: Band
        /// Composite z before the logistic. Positive means better than the user's norm.
        public let compositeZ: Double
        /// Drivers that contributed, ordered as in `Driver.allCases`.
        public let contributions: [Contribution]
        public let hrvBaseline: Baseline
        /// Nil when the resting-HR term was dropped (no usable baseline).
        public let restingHRBaseline: Baseline?
        /// Nil when the respiratory term was dropped (no value, or no usable baseline).
        public let respiratoryRateBaseline: Baseline?
    }

    public enum Outcome: Sendable, Equatable {
        case scored(Score)
        /// The HRV baseline (the dominant driver) is not usable, so no score is produced. This is not
        /// a guess. `status` is `.calibrating` (fewer than `minNightsSeed` valid nights) or `.stale`.
        case insufficientBaseline(status: BaselineStatus, validNights: Int)
    }

    // MARK: - Public API

    /// The colour band for a 0...100 recovery score. Red below 34, yellow below 67, green otherwise.
    public static func band(for score: Double) -> Band {
        if score < bandRedMax { return .red }
        if score < bandYellowMax { return .yellow }
        return .green
    }

    /// Scores one night against the user's own baselines.
    ///
    /// Returns `.insufficientBaseline` when the HRV baseline is not usable. The resting-HR and
    /// respiratory baselines are optional. An unusable one is dropped and its weight renormalised,
    /// as NOOP does (#1988), rather than scoring against a synthetic midpoint.
    public static func score(_ input: Input) -> Outcome {
        let hrvBaseline = fold(input.hrvHistory, config: .hrv)
        // HRV is the dominant driver and required for a score (NOOP `hrvBaselineUsable` gate).
        guard hrvBaseline.usable else {
            return .insufficientBaseline(status: hrvBaseline.status, validNights: hrvBaseline.nValid)
        }

        var terms: [(driver: Driver, z: Double, weight: Double)] = []
        // HRV: higher is better, so (x - mean) / sigma.
        terms.append((.hrv, zScore(input.hrv, mean: hrvBaseline.center, spread: hrvBaseline.spread), wHRV))

        // Resting HR: lower is better, so (mean - x) / sigma.
        let rhrBaseline = fold(input.restingHRHistory, config: .restingHR)
        if rhrBaseline.usable {
            terms.append((.restingHR, zScore(rhrBaseline.center, mean: input.restingHR, spread: rhrBaseline.spread), wRHR))
        }

        // Respiratory rate: lower is better. Needs both tonight's value and a usable baseline.
        let respBaseline = fold(input.respiratoryRateHistory, config: .respiratoryRate)
        if let rr = input.respiratoryRate, respBaseline.usable {
            terms.append((.respiratoryRate, zScore(respBaseline.center, mean: rr, spread: respBaseline.spread), wResp))
        }

        // Sleep performance: no baseline. Centred on 0.85 and scaled by 0.12.
        if let sp = input.sleepPerformance {
            terms.append((.sleep, (sp - sleepPerfCenter) / sleepPerfScale, wSleep))
        }

        let totalWeight = terms.reduce(0.0) { $0 + $1.weight }
        let compositeZ = terms.reduce(0.0) { $0 + $1.z * $1.weight } / totalWeight
        let score = logisticScore(compositeZ: compositeZ)

        // Report drivers in a fixed order. Shares are weight / total, so they sum to 1.
        let contributions: [Contribution] = Driver.allCases.compactMap { driver in
            guard let term = terms.first(where: { $0.driver == driver }) else { return nil }
            return Contribution(driver: driver, weight: term.weight / totalWeight, zScore: term.z)
        }

        return .scored(Score(
            score: score,
            band: band(for: score),
            compositeZ: compositeZ,
            contributions: contributions,
            hrvBaseline: hrvBaseline,
            restingHRBaseline: rhrBaseline.usable ? rhrBaseline : nil,
            respiratoryRateBaseline: (input.respiratoryRate != nil && respBaseline.usable) ? respBaseline : nil
        ))
    }

    // MARK: - Internals

    /// Composite z to 0...100. NOOP `RecoveryScorer.logisticScore(compositeZ:)`.
    static func logisticScore(compositeZ z: Double) -> Double {
        let score = 100.0 / (1.0 + exp(-logisticK * (z - logisticZ0)))
        return max(0.0, min(100.0, score))
    }

    /// Robust z: (value - mean) / max(1.253 x spread, 1e-9). NOOP `RecoveryScorer.zScore`.
    static func zScore(_ value: Double, mean: Double, spread: Double) -> Double {
        let sigma = max(sigmaFactor * spread, 1e-9)
        return (value - mean) / sigma
    }

    /// Per-driver EWMA configuration. Values are NOOP `Baselines.metricCfg`.
    struct Config: Sendable, Equatable {
        /// Physiological lower bound. Values below it are skipped as implausible.
        let minVal: Double
        /// Physiological upper bound. Values above it are skipped as implausible.
        let maxVal: Double
        /// Minimum spread, so an ultra-stable baseline cannot make the z hypersensitive.
        let floorSpread: Double
        /// Half-life of the centre, in nights.
        let halfLifeB: Double
        /// Half-life of the spread, in nights. Slower than the centre.
        let halfLifeS: Double

        /// NOOP `metricCfg["hrv"]`: minVal 5, maxVal 250, floorSpread 5.0, halfLifeB 14, halfLifeS 21.
        static let hrv = Config(minVal: 5.0, maxVal: 250.0, floorSpread: 5.0, halfLifeB: 14.0, halfLifeS: 21.0)
        /// NOOP `metricCfg["resting_hr"]`: minVal 30, maxVal 120, floorSpread 2.0, halfLifeB 14, halfLifeS 21.
        static let restingHR = Config(minVal: 30.0, maxVal: 120.0, floorSpread: 2.0, halfLifeB: 14.0, halfLifeS: 21.0)
        /// NOOP `metricCfg["resp"]`: minVal 4, maxVal 40, floorSpread 0.5, halfLifeB 14, halfLifeS 21.
        static let respiratoryRate = Config(minVal: 4.0, maxVal: 40.0, floorSpread: 0.5, halfLifeB: 14.0, halfLifeS: 21.0)
    }

    /// Mutable fold state. `Baseline` is derived from it at the end, because the status depends on
    /// how many nights have passed since the last valid one.
    private struct FoldState {
        var center: Double
        var spread: Double
        var nValid: Int
        var nightsSinceUpdate: Int
    }

    /// Hard-outlier gate: a night further than this many spreads from the centre is not folded
    /// (NOOP `Baselines.hardOutlierK`). Only applies once the baseline is seeded and not young.
    static let hardOutlierK: Double = 5.0
    /// Winsor clamp: a folded value is clamped to this many spreads from the centre (`winsorK`).
    static let winsorK: Double = 3.0
    /// Valid nights below which the baseline is "young" (`earlyAdaptNights` = 8). While young, the
    /// centre adapts faster, the spread is inflated for the clamp, and the hard-outlier gate is off.
    static let earlyAdaptNights = 8
    static let earlyHalfLifeB: Double = 3.0
    static let earlySpreadInflate: Double = 2.5
    /// Trailing missing nights after which a usable baseline is stale (`staleDays` = 14).
    static let staleDays = 14

    /// EWMA smoothing factor for a half-life in nights. NOOP `Baselines.lambda(halfLife:)`.
    static func lambda(halfLife: Double) -> Double {
        1.0 - pow(0.5, 1.0 / halfLife)
    }

    /// Folds an oldest-first history into a baseline. A nil entry is a missing night and carries the
    /// state forward (NOOP `Baselines.foldHistory`, the incremental fold with hard-outlier rejection on).
    static func fold(_ values: [Double?], config: Config) -> Baseline {
        var state: FoldState?
        for value in values {
            state = update(state, value: value, config: config)
        }
        guard let state else {
            return baseline(FoldState(center: seed(config), spread: config.floorSpread, nValid: 0, nightsSinceUpdate: 0))
        }
        return baseline(state)
    }

    private static func seed(_ config: Config) -> Double {
        (config.minVal + config.maxVal) / 2.0
    }

    private static func baseline(_ state: FoldState) -> Baseline {
        Baseline(center: state.center,
                 spread: state.spread,
                 nValid: state.nValid,
                 status: status(nValid: state.nValid, nightsSinceUpdate: state.nightsSinceUpdate))
    }

    /// NOOP `Baselines.computeStatus`.
    static func status(nValid: Int, nightsSinceUpdate: Int) -> BaselineStatus {
        if nightsSinceUpdate > staleDays && nValid >= minNightsSeed { return .stale }
        if nValid < minNightsSeed { return .calibrating }
        if nValid < minNightsTrust { return .provisional }
        return .trusted
    }

    /// One night folded into the state. NOOP `Baselines.update` (rejectHardOutliers = true).
    private static func update(_ state: FoldState?, value: Double?, config: Config) -> FoldState {
        let lb = lambda(halfLife: config.halfLifeB)
        let ls = lambda(halfLife: config.halfLifeS)

        guard let state else {
            if let value, config.minVal <= value, value <= config.maxVal {
                return FoldState(center: value, spread: config.floorSpread, nValid: 1, nightsSinceUpdate: 0)
            }
            return FoldState(center: seed(config), spread: config.floorSpread, nValid: 0, nightsSinceUpdate: 1)
        }

        // A missing or implausible night is skipped and held. It does not count as a valid night.
        guard let value, config.minVal <= value, value <= config.maxVal else {
            return FoldState(center: state.center, spread: state.spread,
                             nValid: state.nValid, nightsSinceUpdate: state.nightsSinceUpdate + 1)
        }

        let isYoung = state.nValid < earlyAdaptNights
        if state.nValid >= minNightsSeed && !isYoung {
            if abs(value - state.center) > hardOutlierK * state.spread {
                // Seen but not folded. The count and the staleness clock reset, as in NOOP.
                return FoldState(center: state.center, spread: state.spread,
                                 nValid: state.nValid, nightsSinceUpdate: 0)
            }
        }

        // First real value after an empty seed: a clean first night.
        if state.nValid == 0 {
            return FoldState(center: value, spread: config.floorSpread, nValid: 1, nightsSinceUpdate: 0)
        }

        // Winsorised EWMA centre. The spread uses the UNCLAMPED value, so true deviations are tracked.
        let effSpread = isYoung ? state.spread * earlySpreadInflate : state.spread
        let effLb = isYoung ? lambda(halfLife: earlyHalfLifeB) : lb
        let lo = state.center - winsorK * effSpread
        let hi = state.center + winsorK * effSpread
        let clamped = max(lo, min(hi, value))
        let newCenter = effLb * clamped + (1.0 - effLb) * state.center
        let absDev = abs(value - newCenter)
        let newSpread = max(config.floorSpread, ls * absDev + (1.0 - ls) * state.spread)

        return FoldState(center: newCenter, spread: newSpread,
                         nValid: state.nValid + 1, nightsSinceUpdate: 0)
    }
}
