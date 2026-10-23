import Foundation

// Strain.swift: day training load (TRIMP) on a 0-100 logarithmic strain ("Effort") scale.
//
// Ported from NOOP's StrandAnalytics package (read-only reference, Swift):
//   Packages/StrandAnalytics/Sources/StrandAnalytics/StrainScorer.swift
//     strain(...)                      -> Strain.score(...)
//     sampleDurationsMinutes           -> durations (gap clamp, 2 min)
//     edwardsTRIMP / zoneWeight        -> edwardsTRIMP / edwardsWeight
//     banisterTRIMP, banisterBaselineRatePerMinute -> banisterTRIMP, banisterFloorPerMinute
//     trimpToStrain, logMapDenominator -> trimpToStrain, logMapDenominator
//     effortValue(fromWhoopStrain:)    -> effort(fromWhoopStrain:)
//     zoneMinutes                      -> zoneMinutes (six buckets, indexed by Edwards weight)
// Method sources cited in NOOP: Karvonen 1957 (%HRR); Edwards 1993 (5-zone TRIMP); Banister 1991
// (exponential TRIMP, b = 1.92 men / 1.67 women); Tanaka 2001 (HRmax, see HeartRateZones).
//
// APPROXIMATE. This is a labelled, WHOOP-like proxy. It is not WHOOP's Strain, and it is not medical
// advice. The 0-100 output is a log map of TRIMP, not a measured physiological quantity.
//
// Two known departures from the published methods, both inherited from NOOP and kept for parity:
//   1. Edwards 1993 defines the five zone cut-offs (50/60/70/80/90) on %HRmax. NOOP applies them to
//      %HRR (Karvonen). OpenStrap's load_trimp.dart (header, audit MOT-06) found this puts each
//      minute about one zone low at typical resting HR and deleted its copy. Edwards is the default
//      here only because NOOP makes it the default. Treat the Edwards zone split as an estimate.
//   2. Banister's exponential coefficient is 0.64 for both sexes in NOOP. OpenStrap uses 0.86 for
//      women (y = 0.86 e^(1.67x)). NOOP's value is used here.

public enum Strain {

    // MARK: - Constants

    /// Dense-stream gate: samples needed before a day is scored (NOOP `StrainScorer.minReadings`).
    /// That is about 10 minutes at 1 Hz.
    public static let minReadings = 600
    /// Sparse-stream gate: samples needed when the stream spans at least `minSpanSeconds`
    /// (NOOP `minSparseReadings` = 20, #482). It covers a strap that sends HR about every 30 s.
    public static let minSparseReadings = 20
    /// Wall-clock span that qualifies a sparse stream, in seconds (NOOP `minSpanSeconds` = 600).
    public static let minSpanSeconds: Int64 = 600
    /// Longest span one reading may be credited with, in minutes (NOOP `maxSampleGapMin` = 2).
    /// A dropout must not let the reading before it claim the whole gap as effort.
    public static let maxSampleGapMinutes = 2.0
    /// Fallback duration for a sample with no usable successor: one second, as at 1 Hz.
    static let fallbackSampleMinutes = 1.0 / 60.0

    /// Top of the Effort scale (NOOP `StrainScorer.maxStrain` = 100, rescaled from 21 in the redesign).
    public static let maxStrain = 100.0
    /// Top of WHOOP's Day Strain axis (NOOP `StrainScorer.whoopMaxStrain` = 21).
    public static let whoopMaxStrain = 21.0

    /// Edwards log-map denominator D = 7200 + 1 (NOOP `strainDenominator` = 7201). The Edwards
    /// ceiling is zone weight 5 held for 24 h, which is 5 x 1440 = 7200. D is one more, so a theoretical
    /// maximum day maps to exactly 100.
    public static let edwardsDenominator = 7201.0

    /// Banister coefficient c in y = c e^(bx) (NOOP `banisterScale` = 0.64, both sexes).
    public static let banisterScale = 0.64
    /// Banister exponent b for men (Banister 1991; NOOP `banisterBMen` = 1.92).
    public static let banisterBMen = 1.92
    /// Banister exponent b for women (Banister 1991; NOOP `banisterBWomen` = 1.67).
    public static let banisterBWomen = 1.67

    /// %HRR a waking, sedentary body sits at (NOOP `banisterSedentaryHRR` = 0.10). Resting HR is measured
    /// asleep, so awake rest still sits above it. Subtracting this floor per sample stops a desk day from
    /// scoring about 45 on the 0-100 axis (NOOP #1624). It is a judgement, not a measurement. NOOP calls
    /// it calibratable.
    public static let banisterSedentaryHRR = 0.10

    /// Edwards zone cut-offs as (%HRR lower bound, weight), highest first. NOOP `edwardsZones`.
    /// Lower bounds are inclusive.
    static let edwardsCutoffs: [(threshold: Double, weight: Int)] = [
        (90.0, 5), (80.0, 4), (70.0, 3), (60.0, 2), (50.0, 1),
    ]

    // MARK: - Public types

    public enum Method: String, Sendable, Equatable {
        /// Edwards 1993 five-zone summation. The default, as in NOOP.
        case edwards
        /// Banister 1991 exponential TRIMP, minus the sedentary floor.
        case banister
    }

    /// A scored day.
    public struct Score: Sendable, Equatable {
        /// Strain on 0...100 (`maxStrain`). Two decimals, as in NOOP.
        public let strain: Double
        /// The raw accumulated TRIMP, in the method's own units (minute-weights).
        public let trimp: Double
        public let method: Method
        /// Credited minutes in six buckets, indexed by Edwards weight. Index 0 is below 50 % HRR, and
        /// indices 1...5 are zones 1 to 5. The buckets sum to the credited duration, which is not the
        /// wall-clock wear time. Gaps are clamped to `maxSampleGapMinutes`.
        public let zoneMinutes: [Double]
    }

    // MARK: - Public API

    /// Strain for one day of heart-rate samples. Samples flagged `.notDetected` are dropped, as in
    /// `MinuteAggregation`.
    ///
    /// Returns nil when there is too little data to trust the number (see the gate constants), or when
    /// `maxHR <= restingHR`, which leaves no heart-rate reserve.
    ///
    /// - Parameters:
    ///   - samples: any order. They are sorted by time before use.
    ///   - restingHR: resting HR in bpm, the reserve's floor (Karvonen). Use `RestingHR` for a measured value.
    ///   - maxHR: HRmax in bpm. Use `HeartRateZones.maxHR(userEntered:ageYears:)`.
    ///   - method: `.edwards` (default) or `.banister`.
    ///   - sex: selects the Banister exponent. Ignored by Edwards.
    public static func score(_ samples: [HeartRateSample],
                             restingHR: Double,
                             maxHR: Double,
                             method: Method = .edwards,
                             sex: FormulaSex = .male) -> Score? {
        let series = samples
            .filter { $0.contact != .notDetected }
            .map { (tsMs: $0.tsMs, bpm: Double($0.bpm)) }
        return score(series, restingHR: restingHR, maxHR: maxHR, method: method, sex: sex)
    }

    /// Strain from per-minute heart-rate aggregates. Each minute is one reading at its mean bpm, credited
    /// one minute. This is NOOP's per-sample model at a 60 s cadence.
    ///
    /// Minutes with low coverage are not filtered here. Filter them with `MinuteAggregate.coverage`
    /// before calling, if you want that.
    public static func score(minutes: [MinuteAggregate],
                             restingHR: Double,
                             maxHR: Double,
                             method: Method = .edwards,
                             sex: FormulaSex = .male) -> Score? {
        let series = minutes.map { (tsMs: $0.minuteMs, bpm: $0.hrAvg) }
        return score(series, restingHR: restingHR, maxHR: maxHR, method: method, sex: sex)
    }

    /// TRIMP to 0-100 on a log axis: 100 x ln(TRIMP + 1) / ln(D), two decimals. NOOP `trimpToStrain`.
    /// TRIMP <= 0, or D <= 1, returns 0. The result is clamped to 0...100. NOOP does not clamp here, but
    /// that only matters with more than 24 h of data.
    public static func trimpToStrain(_ trimp: Double, denominator: Double = edwardsDenominator) -> Double {
        guard trimp > 0, denominator > 1 else { return 0 }
        let value = maxStrain * log(trimp + 1.0) / log(denominator)
        let clamped = min(max(value, 0), maxStrain)
        return (clamped * 100).rounded() / 100
    }

    /// The log-map denominator that belongs to a method. NOOP `logMapDenominator(method:sex:)`.
    /// Edwards is 7201. Banister is its own sex-dependent daily ceiling, minus a sedentary day, plus one.
    /// Reusing one denominator for both methods would rescale the axis (NOOP #1545).
    public static func logMapDenominator(method: Method, sex: FormulaSex) -> Double {
        switch method {
        case .edwards:
            return edwardsDenominator
        case .banister:
            let b = banisterExponent(sex)
            let ceiling = 24.0 * 60.0 * banisterScale * exp(b)
            let baseline = banisterFloorPerMinute(b: b) * 24.0 * 60.0
            return ceiling - baseline + 1.0
        }
    }

    /// Maps a WHOOP 0-21 Day Strain value onto this 0-100 Effort axis. NOOP `effortValue(fromWhoopStrain:)`.
    public static func effort(fromWhoopStrain value: Double) -> Double {
        value * (maxStrain / whoopMaxStrain)
    }

    /// The inverse of `effort(fromWhoopStrain:)`: 0-100 Effort onto WHOOP's 0-21 axis. This is our
    /// inverse for display. NOOP does not define it.
    public static func whoopStrain(fromEffort value: Double) -> Double {
        value * (whoopMaxStrain / maxStrain)
    }

    // MARK: - Internals

    /// Shared core. Takes timestamps in ms and bpm. Both public entry points reduce to this.
    private static func score(_ series: [(tsMs: Int64, bpm: Double)],
                              restingHR: Double,
                              maxHR: Double,
                              method: Method,
                              sex: FormulaSex) -> Score? {
        // The reserve must be positive. NOOP refuses the day when maxHR <= restingHR.
        guard maxHR > restingHR else { return nil }

        let sorted = series.sorted { ($0.tsMs, $0.bpm) < ($1.tsMs, $1.bpm) }
        guard hasEnoughData(sorted) else { return nil }

        let durations = durationsMinutes(sorted.map { $0.tsMs })
        let reserve = maxHR - restingHR
        let bpms = sorted.map { $0.bpm }

        let trimp: Double
        switch method {
        case .edwards:
            trimp = edwardsTRIMP(bpms, restingHR: restingHR, reserve: reserve, durations: durations)
        case .banister:
            trimp = banisterTRIMP(bpms, restingHR: restingHR, reserve: reserve, durations: durations,
                                  b: banisterExponent(sex))
        }

        let denominator = logMapDenominator(method: method, sex: sex)
        return Score(strain: trimpToStrain(trimp, denominator: denominator),
                     trimp: trimp,
                     method: method,
                     zoneMinutes: zoneMinutes(bpms, restingHR: restingHR, reserve: reserve, durations: durations))
    }

    /// Enough data to trust the number. Either a dense stream (`minReadings`), or a sparse one with at
    /// least `minSparseReadings` samples spanning at least `minSpanSeconds`. NOOP `strainUncached`.
    static func hasEnoughData(_ sorted: [(tsMs: Int64, bpm: Double)]) -> Bool {
        if sorted.count >= minReadings { return true }
        guard sorted.count >= minSparseReadings, let first = sorted.first, let last = sorted.last else {
            return false
        }
        return last.tsMs - first.tsMs >= minSpanSeconds * 1000
    }

    /// Minutes each reading covers. Each reading covers the gap to the next one, clamped to
    /// `maxSampleGapMinutes`. The last reuses the gap before it. A zero gap falls back to one second.
    /// NOOP `sampleDurationsMinutes` (#950).
    static func durationsMinutes(_ timesMs: [Int64]) -> [Double] {
        if timesMs.isEmpty { return [] }
        if timesMs.count == 1 { return [fallbackSampleMinutes] }
        var out: [Double] = []
        out.reserveCapacity(timesMs.count)
        for i in 0..<(timesMs.count - 1) {
            let deltaMs = abs(timesMs[i + 1] - timesMs[i])
            let minutes = deltaMs > 0 ? Double(deltaMs) / 60_000.0 : fallbackSampleMinutes
            out.append(min(minutes, maxSampleGapMinutes))
        }
        out.append(out[out.count - 1])
        return out
    }

    /// Karvonen %HRR, clamped to 0...100. NOOP `pctHRR`.
    static func percentHRR(_ bpm: Double, restingHR: Double, reserve: Double) -> Double {
        let pct = (bpm - restingHR) / reserve * 100.0
        return min(max(pct, 0), 100)
    }

    /// Edwards weight from %HRR, 0 to 5. Unclamped, as NOOP `zoneWeight`. Below 50 % HRR is 0.
    static func edwardsWeight(_ bpm: Double, restingHR: Double, reserve: Double) -> Int {
        let pct = (bpm - restingHR) / reserve * 100.0
        for (threshold, weight) in edwardsCutoffs where pct >= threshold {
            return weight
        }
        return 0
    }

    /// Sum of weight x duration. NOOP `edwardsTRIMP`.
    static func edwardsTRIMP(_ bpms: [Double], restingHR: Double, reserve: Double, durations: [Double]) -> Double {
        var acc = 0.0
        for i in bpms.indices {
            acc += Double(edwardsWeight(bpms[i], restingHR: restingHR, reserve: reserve)) * durations[i]
        }
        return acc
    }

    /// Banister exponent for a sex. NOOP selects b by `hasPrefix("f")` on the lowercased string.
    static func banisterExponent(_ sex: FormulaSex) -> Double {
        switch sex {
        case .male: return banisterBMen
        case .female: return banisterBWomen
        }
    }

    /// TRIMP per minute at the sedentary floor. NOOP `banisterBaselineRatePerMinute`.
    static func banisterFloorPerMinute(b: Double) -> Double {
        banisterScale * banisterSedentaryHRR * exp(b * banisterSedentaryHRR)
    }

    /// Banister TRIMP above the sedentary floor, per sample and floored at zero. Each sample contributes
    /// duration x max(rate - floor, 0), where rate = x c e^(bx) and x = %HRR / 100. NOOP `banisterTRIMP`
    /// (#1624). Flooring per sample means a quiet stretch cannot cancel real work done elsewhere in the day.
    static func banisterTRIMP(_ bpms: [Double], restingHR: Double, reserve: Double,
                              durations: [Double], b: Double) -> Double {
        let floor = banisterFloorPerMinute(b: b)
        var acc = 0.0
        for i in bpms.indices {
            let x = percentHRR(bpms[i], restingHR: restingHR, reserve: reserve) / 100.0
            if x > 0 {
                let rate = x * banisterScale * exp(b * x)
                acc += durations[i] * max(rate - floor, 0.0)
            }
        }
        return acc
    }

    /// Credited minutes per Edwards weight, six buckets. NOOP `zoneMinutes`. Index 0 is below 50 % HRR.
    static func zoneMinutes(_ bpms: [Double], restingHR: Double, reserve: Double, durations: [Double]) -> [Double] {
        var out = [Double](repeating: 0.0, count: 6)
        for i in bpms.indices {
            out[edwardsWeight(bpms[i], restingHR: restingHR, reserve: reserve)] += durations[i]
        }
        return out
    }
}
