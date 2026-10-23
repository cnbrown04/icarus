import Foundation

/// One stage in a hypnogram. Segment strings canonically spell wakefulness `"wake"`.
public enum SleepStage: String, Sendable, Equatable, CaseIterable, Codable {
    case wake
    case light
    case deep
    case rem
}

/// One contiguous staged interval, unix seconds, half-open `[startUnix, endUnix)`.
public struct StageSegment: Sendable, Equatable, Codable {
    public var startUnix: Int64
    public var endUnix: Int64
    public let stage: SleepStage

    public var durationSeconds: Int64 { max(0, endUnix - startUnix) }

    public init(startUnix: Int64, endUnix: Int64, stage: SleepStage) {
        self.startUnix = startUnix
        self.endUnix = endUnix
        self.stage = stage
    }
}

/// The result of staging one in-bed window.
public struct SleepStaging: Sendable, Equatable {
    /// Segments tile `[fromUnix, toUnix)` with no gaps or overlaps. Empty when the window had no
    /// usable staging input (or was empty/degenerate).
    public let segments: [StageSegment]
    /// Total seconds per stage. Every `SleepStage` case is present; absent stages are 0.
    public let stageSeconds: [SleepStage: Int]
    /// Asleep seconds (light + deep + rem) divided by in-bed seconds, 0...1. Wake is NOT asleep.
    public let efficiency: Double
    /// The caller's resting HR when supplied, otherwise the lowest 5-minute rolling mean HR in the
    /// window (nil when the window carries no HR). Metadata only — the recipe does not consume it.
    public let restingHR: Double?

    public init(
        segments: [StageSegment],
        stageSeconds: [SleepStage: Int],
        efficiency: Double,
        restingHR: Double?
    ) {
        self.segments = segments
        self.stageSeconds = stageSeconds
        self.efficiency = efficiency
        self.restingHR = restingHR
    }
}

/// One decoded historical record reduced to the fields sleep staging consumes.
///
/// This is deliberately protocol-free, like `SleepRecord`: callers map BandProtocol / the store into
/// it so Metrics stays a pure package.
///
/// Our history audit (and NOOP's own input contract) makes the usable staging channels **gravity,
/// bpm and rr_ms**. `resp_rate_raw` is a constant in our stored rows, `signal_quality` is constant,
/// and `spo2_red` / `spo2_ir` are constant, so none of them carry staging signal and none are here.
/// Respiration regularity is recovered from the R-R stream (RSA), exactly as NOOP V2 does.
public struct StagingRecord: Sendable, Equatable {
    /// A gravity vector in g.
    public struct Gravity: Sendable, Equatable {
        public let x: Double
        public let y: Double
        public let z: Double

        public init(x: Double, y: Double, z: Double) {
            self.x = x
            self.y = y
            self.z = z
        }
    }

    /// Record unix time, seconds.
    public let tsUnix: Int64
    /// Heart rate (bpm), nil when the strap recorded no reading.
    public let bpm: Double?
    /// Skin contact. Retained for callers, but NOOP V2's recipe does not consume it.
    public let contact: Bool
    /// R-R intervals (ms) carried by this record.
    public let rrMs: [Double]
    /// Gravity vector, nil when the row predates v3 or the strap omitted it.
    public let gravity: Gravity?

    public init(
        tsUnix: Int64,
        bpm: Double?,
        contact: Bool,
        rrMs: [Double],
        gravity: Gravity?
    ) {
        self.tsUnix = tsUnix
        self.bpm = bpm
        self.contact = contact
        self.rrMs = rrMs
        self.gravity = gravity
    }
}

/// NOOP's default sleep-staging recipe (SleepStagerV2), ported to Icarus' stored data.
///
/// Upstream reference (fetched 2026-10-19, commit `ef165de4`):
/// `Packages/StrandAnalytics/Sources/StrandAnalytics/SleepStagerV2.swift` in ryanbr/noop. The recipe
/// is reimplemented here over our own value types. Session DETECTION lives in `SleepDetector` (a port
/// of NOOP's Stage 0); this file only stages a window the detector decided is sleep (exactly V2's
/// contract upstream).
///
/// V2 stages each 30 s epoch from:
///   1. per-night z-scored HR mean / HR variance / movement;
///   2. a per-night DEEP gate on the 11-minute HR-flatness percentile;
///   3. a soft sleep-cycle prior (deep early, REM rising, REM-latency guard in minutes);
///   4. a peak-motion (jerk) wake gate relative to the night's own quiescent jerk floor;
///   5. R-R RSA respiration regularity (regular → deep, irregular → REM);
///   6. Viterbi/HMM transition smoothing.
///
/// All coefficients below are fixed a-priori from sleep physiology + population base rates, not fit
/// to labels. These stages are APPROXIMATIONS, not PSG-validated and not medical advice.
///
/// HONEST DEGENERATE CASE: upstream falls back to a single `light` block when no epoch can be built.
/// We return an EMPTY staging instead, per this package's API contract ("empty/degenerate input
/// returns empty") so a caller never mistakes a fabricated all-light night for measured data.
public enum SleepStager {
    /// Algorithm version stored with every derived segment row (cache-busting key).
    /// Bump when the recipe or its constants change.
    public static let algoVersion = 1

    /// NOOP V2's epoch length.
    public static let epochSeconds: Int64 = 30
    /// Sessions shorter than this are not staged (~10 minutes). Tunable.
    public static let minimumSessionSeconds: Int64 = 10 * 60

    // MARK: - Public entry point

    /// Stage `[fromUnix, toUnix)` from the records that overlap the window plus V2's feature padding.
    ///
    /// Pure, deterministic, no database. `records` may be in any order; duplicates are consumed as
    /// given (the store's `UNIQUE(band_id, ts_ms)` already dedupes). `restingHR` is metadata — the
    /// recipe does not use it, matching upstream V2.
    public static func stage(
        records: [StagingRecord],
        fromUnix: Int64,
        toUnix: Int64,
        restingHR: Double?
    ) -> SleepStaging {
        guard toUnix > fromUnix, !records.isEmpty else {
            return emptyStaging(restingHR: restingHR)
        }

        // V2 clips each stream to the widest reach of any per-epoch window before featurising:
        // 330 s back (11-min flatness window) and 390 s forward (its trailing edge).
        let lo = fromUnix - padLo
        let hi = toUnix + padHi
        let windowRecords = records.enumerated()
            .filter { $0.element.tsUnix >= lo && $0.element.tsUnix < hi }
            .sorted { lhs, rhs in
                if lhs.element.tsUnix != rhs.element.tsUnix {
                    return lhs.element.tsUnix < rhs.element.tsUnix
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)

        var grav: [GravityPoint] = []
        var hr: [HRPoint] = []
        var rr: [RRPoint] = []
        for record in windowRecords {
            if let gravity = record.gravity {
                grav.append(GravityPoint(ts: record.tsUnix, x: gravity.x, y: gravity.y, z: gravity.z))
            }
            if let bpm = record.bpm {
                hr.append(HRPoint(ts: record.tsUnix, bpm: bpm))
            }
            for value in record.rrMs {
                rr.append(RRPoint(ts: record.tsUnix, rrMs: value))
            }
        }

        let start = Int(clamping: fromUnix)
        let end = Int(clamping: toUnix)
        let feats = features(start: start, end: end, grav: grav, hr: hr, rr: rr)
        guard !feats.isEmpty else {
            return emptyStaging(restingHR: restingHR)
        }

        let labels = stageEpochs(feats)

        // Tile [start, end] with one segment per staged epoch. The first segment back-fills
        // [start, firstEpoch) and the last extends to `end`; an interior coverage gap is carried by
        // the preceding label. "awake" is renamed to the canonical "wake".
        var segments: [StageSegment] = []
        segments.reserveCapacity(labels.count)
        for (index, feature) in feats.enumerated() {
            let stage: SleepStage = labels[index] == "awake" ? .wake : (SleepStage(rawValue: labels[index]) ?? .light)
            let segStart = index == 0 ? fromUnix : Int64(feature.start)
            let segEnd = index == feats.count - 1 ? toUnix : Int64(feats[index + 1].start)
            if let last = segments.last, last.stage == stage {
                segments[segments.count - 1].endUnix = segEnd
            } else {
                segments.append(StageSegment(startUnix: segStart, endUnix: segEnd, stage: stage))
            }
        }

        var stageSeconds = Dictionary(uniqueKeysWithValues: SleepStage.allCases.map { ($0, 0) })
        var asleepSeconds: Int64 = 0
        var inBedSeconds: Int64 = 0
        for segment in segments {
            let seconds = max(0, segment.endUnix - segment.startUnix)
            stageSeconds[segment.stage, default: 0] += Int(clamping: seconds)
            inBedSeconds += seconds
            if segment.stage != .wake {
                asleepSeconds += seconds
            }
        }
        let efficiency = inBedSeconds > 0
            ? min(1.0, max(0.0, Double(asleepSeconds) / Double(inBedSeconds)))
            : 0.0

        return SleepStaging(
            segments: segments,
            stageSeconds: stageSeconds,
            efficiency: efficiency,
            restingHR: restingHR ?? sessionRestingHR(start: start, end: end, hr: hr)
        )
    }

    private static func emptyStaging(restingHR: Double?) -> SleepStaging {
        SleepStaging(
            segments: [],
            stageSeconds: Dictionary(uniqueKeysWithValues: SleepStage.allCases.map { ($0, 0) }),
            efficiency: 0,
            restingHR: restingHR
        )
    }

    /// Lowest 5-minute rolling-mean HR in the window (the V1/NOOP session resting-HR rule), used
    /// only when the caller did not supply one.
    private static func sessionRestingHR(start: Int, end: Int, hr: [HRPoint]) -> Double? {
        let segment = hr.filter { $0.ts >= start && $0.ts <= end }
        guard !segment.isEmpty else { return nil }
        let windowS = 5 * 60
        var means: [Double] = []
        var t = start
        while t < end {
            let values = segment.filter { $0.ts >= t && $0.ts < t + windowS }.map(\.bpm)
            if !values.isEmpty {
                means.append(values.reduce(0, +) / Double(values.count))
            }
            t += windowS
        }
        if let minimum = means.min() {
            return minimum
        }
        return segment.map(\.bpm).reduce(0, +) / Double(segment.count)
    }

    // MARK: - Recipe constants (all fixed a-priori — NOT fit to labels)

    static let stageNames = ["deep", "rem", "light", "awake"]

    /// Population sleep-architecture base rates as log-priors (adult TST ≈ light 50 / deep 18 /
    /// rem 22 / waso 10 %). Calibrates the boundary so light wins weak-evidence epochs.
    static let baseLogPrior: [String: Double] = [
        "light": log(0.50), "deep": log(0.18), "rem": log(0.22), "awake": log(0.10),
    ]

    /// Deep is eligible only in the night's lowest ~25 % HR-flatness epochs (≈ deep base rate + margin).
    static let deepGateThresh = 0.25
    static let deepGateSlope = 5.0

    /// Motion thresholds are RELATIVE to each night's own quiescent jerk floor (the median per-second
    /// gravity-jerk over the in-bed session), NOT an absolute g.
    static let jerkFloorMoveMult = 38.0
    static let jerkFloorGateMult = 55.0
    static let motionGateBoost = 2.0

    /// Motion-corroborated wake: on a motion-quiescent epoch the wake-PROMOTING cardiac evidence is
    /// discarded (a raised HR with a motionless wrist is an artefact), while its sleep-promoting half
    /// is kept.
    static func motionQuiescent(_ feature: Epoch) -> Bool {
        feature.moveFrac <= 0.0 && feature.jerkMax <= feature.jerkScale * jerkFloorGateMult
    }

    /// Weight of the RSA respiration-regularity term (regular → deep, irregular → REM).
    static let respWeight = 0.6

    /// Transition matrix (rows = from, cols = to). Self-transitions dominate; deep↔rem rare; wake
    /// mostly to/from light. A sleeper does not enter deep or REM straight out of wakefulness, so
    /// those entries are zero and `viterbi` floors the log at 1e-9.
    static let transition: [String: [String: Double]] = [
        "deep": ["deep": 0.86, "rem": 0.007, "light": 0.126, "awake": 0.007],
        "rem": ["deep": 0.005, "rem": 0.88, "light": 0.10, "awake": 0.015],
        "light": ["deep": 0.06, "rem": 0.06, "light": 0.85, "awake": 0.03],
        "awake": ["deep": 0.0, "rem": 0.0, "light": 0.10, "awake": 0.90],
    ]

    /// One 30 s epoch's recipe features. Optionals are "no measurement"; the z-score / percentile
    /// treat a missing value as the neutral centre so a sparse channel never blocks a stage.
    struct Epoch {
        let start: Int
        let hr: Double?
        let hrVar: Double?
        let hrFlat11: Double?
        let moveFrac: Double
        let jerkMax: Double
        let respReg: Double?
        let clock: Double
        let jerkScale: Double
        /// Elapsed minutes from the window start to this epoch's centre. The REM-latency guard is
        /// re-based onto the sleep onset found by pass 1.
        let minutesSinceOnset: Double
    }

    /// Farthest seconds, relative to an epoch, that `features` reads any input: the 11-minute
    /// HR-flatness window reaches 330 s back and 390 s forward. Public so a store can read exactly
    /// the rows the recipe can consume around a session edge.
    public static let padLo: Int64 = 330
    public static let padHi: Int64 = 390

    // MARK: - Feature extraction

    struct GravityPoint {
        let ts: Int64
        let x: Double
        let y: Double
        let z: Double
    }

    struct HRPoint {
        let ts: Int64
        let bpm: Double
    }

    struct RRPoint {
        let ts: Int64
        let rrMs: Double
    }

    /// Build the per-epoch recipe features over a 30 s wall-clock-aligned grid covering [start, end].
    static func features(
        start: Int,
        end: Int,
        grav: [GravityPoint],
        hr: [HRPoint],
        rr: [RRPoint]
    ) -> [Epoch] {
        if end <= start { return [] }
        let span = Double(max(1, end - start))

        // Per-second aggregation (mean when a second carries several samples).
        var hrSum = [Int: Double](), hrCnt = [Int: Int]()
        for sample in hr {
            let second = Int(clamping: sample.ts)
            hrSum[second, default: 0] += sample.bpm
            hrCnt[second, default: 0] += 1
        }
        var secHR = [Int: Double]()
        secHR.reserveCapacity(hrSum.count)
        for (second, sum) in hrSum {
            secHR[second] = sum / Double(hrCnt[second]!)
        }

        var gxSum = [Int: Double](), gySum = [Int: Double](), gzSum = [Int: Double](), gCnt = [Int: Int]()
        for sample in grav {
            let second = Int(clamping: sample.ts)
            gxSum[second, default: 0] += sample.x
            gySum[second, default: 0] += sample.y
            gzSum[second, default: 0] += sample.z
            gCnt[second, default: 0] += 1
        }
        var secG = [Int: (Double, Double, Double)]()
        secG.reserveCapacity(gCnt.count)
        for (second, count) in gCnt {
            let divisor = Double(count)
            secG[second] = (gxSum[second]! / divisor, gySum[second]! / divisor, gzSum[second]! / divisor)
        }

        // R-R values bucketed by second (for the RSA respiration window).
        var rrBy = [Int: [Double]]()
        for beat in rr {
            rrBy[Int(clamping: beat.ts), default: []].append(Double(beat.rrMs))
        }

        // Prefix sums over the per-second HR grid. Every epoch evaluates a 5-min AND an 11-min
        // centred std window; O(1) range queries keep a cold full-history pass tractable.
        let gridLo = secHR.keys.min()
        let gridHi = secHR.keys.max()
        var prefixCount = [Int](), prefixSum = [Double](), prefixSq = [Double]()
        if let gridLo, let gridHi {
            let n = gridHi - gridLo + 1
            prefixCount = [Int](repeating: 0, count: n + 1)
            prefixSum = [Double](repeating: 0, count: n + 1)
            prefixSq = [Double](repeating: 0, count: n + 1)
            for index in 0..<n {
                let value = secHR[gridLo + index]
                prefixCount[index + 1] = prefixCount[index] + (value == nil ? 0 : 1)
                prefixSum[index + 1] = prefixSum[index] + (value ?? 0)
                prefixSq[index + 1] = prefixSq[index] + (value.map { $0 * $0 } ?? 0)
            }
        }
        // Population std over the PRESENT per-second HR in `[lo, hi)`; nil when < 2 present samples.
        func stdOfSeconds(_ lo: Int, _ hi: Int) -> Double? {
            guard let gridLo, let gridHi else { return nil }
            let a = max(lo, gridLo) - gridLo
            let b = min(hi, gridHi + 1) - gridLo
            if b <= a { return nil }
            let count = prefixCount[b] - prefixCount[a]
            if count < 2 { return nil }
            let n = Double(count)
            let sum = prefixSum[b] - prefixSum[a]
            let squareSum = prefixSq[b] - prefixSq[a]
            let mean = sum / n
            let variance = (squareSum - 2 * mean * sum + n * mean * mean) / n
            return (variance < 0 ? 0 : variance).squareRoot()
        }

        // PASS 1 — every per-epoch quantity EXCEPT the move fraction, and pool every per-second jerk
        // so the night's quiescent jerk floor (its median) can scale the motion thresholds.
        struct Raw {
            let start: Int
            let hr: Double?
            let hrVar: Double?
            let hrFlat11: Double?
            let jerks: [Double]
            let gapSec: Int
            let jerkMax: Double
            let respReg: Double?
            let clock: Double
            let minutes: Double
        }
        var raws: [Raw] = []
        var allJerks: [Double] = []
        let firstEpoch = ((start + 29) / 30) * 30
        var epoch = firstEpoch
        while epoch < end {
            var hrs: [Double] = []
            var gseq: [(Double, Double, Double)] = []
            for second in epoch..<(epoch + 30) {
                if let value = secHR[second] { hrs.append(value) }
                if let value = secG[second] { gseq.append(value) }
            }
            if hrs.isEmpty && gseq.isEmpty {
                epoch += 30
                continue // no coverage → skip the epoch
            }

            // Movement: consecutive per-second gravity jerks within the epoch.
            var jerks: [Double] = []
            for index in 1..<max(1, gseq.count) {
                let previous = gseq[index - 1], current = gseq[index]
                let dx = previous.0 - current.0
                let dy = previous.1 - current.1
                let dz = previous.2 - current.2
                jerks.append((dx * dx + dy * dy + dz * dz).squareRoot())
            }
            allJerks.append(contentsOf: jerks)
            let jerkMax = jerks.max() ?? 0.0

            let hrMean = hrs.isEmpty ? nil : hrs.reduce(0, +) / Double(hrs.count)
            let hrVar = stdOfSeconds(epoch - 150, epoch + 30 + 150) // 5-min centred window
            let hrFlat11 = stdOfSeconds(epoch - 330, epoch + 30 + 360) // 11-min centred window

            // RSA respiration over a wider beat window [e-90, e+120).
            var beats: [(Double, Double)] = []
            for second in (epoch - 90)..<(epoch + 120) {
                if let values = rrBy[second] {
                    for value in values {
                        beats.append((Double(second), min(max(value, 300), 2000)))
                    }
                }
            }
            beats.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
            let respReg = respRegularity(beats)

            raws.append(Raw(
                start: epoch,
                hr: hrMean,
                hrVar: hrVar,
                hrFlat11: hrFlat11,
                jerks: jerks,
                gapSec: max(1, gseq.count - 1),
                jerkMax: jerkMax,
                respReg: respReg,
                clock: Double(epoch + 15 - start) / span,
                minutes: Double(epoch + 15 - start) / 60.0
            ))
            epoch += 30
        }

        // Night quiescent jerk floor = median of all per-second jerks (most sleep seconds are still,
        // so the median tracks the strap's noise/decode floor). Tiny epsilon when there is no motion
        // data so the move threshold collapses to ~0 rather than dividing by nothing.
        let jerkScale: Double = {
            if allJerks.isEmpty { return 1e-6 }
            let sorted = allJerks.sorted()
            let count = sorted.count
            return count % 2 == 1
                ? sorted[count / 2]
                : 0.5 * (sorted[count / 2 - 1] + sorted[count / 2])
        }()
        let moveThreshold = jerkScale * jerkFloorMoveMult

        // PASS 2 — move fraction against the night-relative threshold; carry the floor on each epoch
        // so the wake gate in stageEpochs() can be night-relative too.
        var features: [Epoch] = []
        features.reserveCapacity(raws.count)
        for raw in raws {
            let moves = raw.jerks.reduce(0) { $0 + ($1 > moveThreshold ? 1 : 0) }
            features.append(Epoch(
                start: raw.start,
                hr: raw.hr,
                hrVar: raw.hrVar,
                hrFlat11: raw.hrFlat11,
                moveFrac: Double(moves) / Double(raw.gapSec),
                jerkMax: raw.jerkMax,
                respReg: raw.respReg,
                clock: raw.clock,
                jerkScale: jerkScale,
                minutesSinceOnset: raw.minutes
            ))
        }
        return features
    }

    /// RSA respiration regularity: tachogram → 4 Hz resample → detrend (mean removal) → power
    /// spectrum → peak/sum of the 0.15–0.40 Hz (9–24 brpm) band. Returns spectral peakedness (higher
    /// = more regular breathing) or nil when there are too few beats. A direct band-limited DFT.
    static func respRegularity(_ beats: [(Double, Double)]) -> Double? {
        if beats.count < 12 { return nil }
        let t0 = beats.first!.0, tN = beats.last!.0
        if tN <= t0 { return nil }
        let n = Int(ceil((tN - t0) / 0.25 - 1e-9)) // np.arange(t0, tN, 0.25) length
        if n < 16 { return nil }

        // Linear resample onto the uniform 4 Hz grid (clamped within [t0, tN]).
        var y = [Double](repeating: 0, count: n)
        var segment = 0
        for index in 0..<n {
            let t = t0 + 0.25 * Double(index)
            while segment < beats.count - 2 && beats[segment + 1].0 < t { segment += 1 }
            let ta = beats[segment].0, tb = beats[segment + 1].0
            let va = beats[segment].1, vb = beats[segment + 1].1
            y[index] = tb <= ta ? va : va + min(max((t - ta) / (tb - ta), 0), 1) * (vb - va)
        }
        let mean = y.reduce(0, +) / Double(n)
        for index in 0..<n { y[index] -= mean }

        // Band bins: f[k] = k / (n·0.25); keep 0.15 ≤ f ≤ 0.40.
        let kLo = Int(ceil(0.15 * 0.25 * Double(n)))
        let kHi = Int(floor(0.40 * 0.25 * Double(n)))
        if kHi < kLo || kLo < 0 { return nil }
        var maxPower = 0.0, sumPower = 0.0
        for k in kLo...kHi {
            var real = 0.0, imaginary = 0.0
            let w = -2.0 * Double.pi * Double(k) / Double(n)
            for index in 0..<n {
                let angle = w * Double(index)
                real += y[index] * cos(angle)
                imaginary += y[index] * sin(angle)
            }
            let power = real * real + imaginary * imaginary
            sumPower += power
            if power > maxPower { maxPower = power }
        }
        if sumPower == 0 { return nil }
        return maxPower / sumPower
    }

    // MARK: - Recipe staging

    /// Log-odds penalty applied to the REM emission at sleep onset; decays linearly to zero over
    /// `remLatencyMinutes`. e⁻³ ≈ 0.05 — strong suppression that sufficient evidence still overcomes,
    /// never a veto.
    static let remLatencyPenalty = 3.0
    static let remLatencyMinutes = 60.0

    /// `K` at (and before) sleep onset, linearly decaying to 0 at `remLatencyMinutes` after it.
    /// Clamped to `[0, K]` so a pre-onset epoch can never be penalised harder than the onset instant.
    static func remLatencyGuard(_ minutesSinceOnset: Double) -> Double {
        remLatencyPenalty * min(1.0, max(0.0, 1.0 - minutesSinceOnset / remLatencyMinutes))
    }

    /// Soft sleep-cycle prior added to the log-emission: deep concentrated early (decays, never
    /// hard-wiped); REM suppressed around sleep onset then rising toward morning.
    static func cyclePrior(_ fraction: Double, _ minutesSinceOnset: Double) -> [String: Double] {
        [
            "deep": 1.2 * max(0.0, 1.0 - fraction / 0.55),
            "rem": 1.0 * fraction - remLatencyGuard(minutesSinceOnset),
            "light": 0.0,
            "awake": 0.0,
        ]
    }

    /// Sustained non-wake run, in 30 s epochs, that establishes sleep onset — 10 epochs = 5 minutes.
    static let onsetSustainedEpochs = 10

    /// Index of the first epoch beginning a run of `onsetSustainedEpochs` consecutive non-"awake"
    /// labels, or nil when the hypnogram never sustains sleep that long.
    static func sustainedSleepOnset(_ labels: [String]) -> Int? {
        var run = 0
        for index in labels.indices {
            if labels[index] == "awake" {
                run = 0
                continue
            }
            run += 1
            if run >= onsetSustainedEpochs {
                return index - onsetSustainedEpochs + 1
            }
        }
        return nil
    }

    /// Viterbi most-likely path over per-epoch log-emissions with the sticky transition matrix and
    /// a uniform start. Ties resolve to the earlier stage in `stageNames`.
    static func viterbi(_ emissions: [[String: Double]]) -> [String] {
        if emissions.isEmpty { return [] }
        // Floor before ln so a zeroed transition entry can never hit ln(0) = -Inf and poison the
        // lattice. LOAD-BEARING: the awake row carries wake→deep = wake→rem = 0.0.
        let logTransition = transition.mapValues { row in row.mapValues { log(max($0, 1e-9)) } }
        var values = emissions[0] // uniform start
        var back: [[String: String]] = []
        for time in 1..<emissions.count {
            var nextValues = [String: Double](), backPointers = [String: String]()
            for state in stageNames {
                var bestPrevious = stageNames[0]
                var bestValue = values[bestPrevious]! + logTransition[bestPrevious]![state]!
                for previous in stageNames.dropFirst() {
                    let value = values[previous]! + logTransition[previous]![state]!
                    if value > bestValue {
                        bestValue = value
                        bestPrevious = previous
                    }
                }
                nextValues[state] = bestValue + emissions[time][state]!
                backPointers[state] = bestPrevious
            }
            values = nextValues
            back.append(backPointers)
        }
        var last = stageNames[0], lastValue = values[last]!
        for state in stageNames.dropFirst() where values[state]! > lastValue {
            lastValue = values[state]!
            last = state
        }
        var path = [last]
        for backPointer in back.reversed() {
            last = backPointer[last]!
            path.append(last)
        }
        return path.reversed()
    }

    /// Run the full recipe over a night's epochs and return one stage label per epoch (incl. "awake").
    /// All normalisation (z-scores, the HR-flatness percentile) is WITHIN the night.
    ///
    /// TWO PASSES. The REM-latency guard is measured from sleep onset, and onset is itself a staging
    /// output, so pass 1 stages with the guard DISABLED and reads the first sustained sleep run; pass 2
    /// adds the guard re-based on that onset and re-runs Viterbi. When no sustained run exists the
    /// origin falls back to the window start.
    static func stageEpochs(_ features: [Epoch]) -> [String] {
        if features.isEmpty { return [] }

        // Per-night z-score over the present values (population std; 0 std → 1 so a flat channel is
        // neutral).
        func zScore(_ values: [Double?]) -> (Double?) -> Double {
            let present = values.compactMap { $0 }
            if present.isEmpty { return { _ in 0.0 } }
            let mean = present.reduce(0, +) / Double(present.count)
            let sd0 = (present.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(present.count)).squareRoot()
            let sd = sd0 == 0 ? 1.0 : sd0
            return { value in value == nil ? 0.0 : (value! - mean) / sd }
        }
        let zHR = zScore(features.map(\.hr))
        let zHRV = zScore(features.map(\.hrVar))
        let zMove = zScore(features.map { Optional($0.moveFrac) })
        let zResp = zScore(features.map(\.respReg))

        // HR-flatness percentile rank within the night (bisect_right / n), neutral 0.5 when missing.
        let flatSorted = features.compactMap(\.hrFlat11).sorted()
        func flatPercentile(_ value: Double?) -> Double {
            guard let value, !flatSorted.isEmpty else { return 0.5 }
            var low = 0, high = flatSorted.count
            while low < high {
                let mid = (low + high) / 2
                if flatSorted[mid] <= value { low = mid + 1 } else { high = mid }
            }
            return Double(low) / Double(flatSorted.count)
        }

        var sequence: [[String: Double]] = []
        sequence.reserveCapacity(features.count)
        for feature in features {
            let zHRVValue = zHRV(feature.hrVar)
            let zMoveValue = zMove(feature.moveFrac)
            let zHRValue = zHR(feature.hr)
            let gate = deepGateSlope * max(0.0, flatPercentile(feature.hrFlat11) - deepGateThresh)
            // Cardiac contribution to the AWAKE emission. A quiescent wrist keeps only its
            // wake-SUPPRESSING (pro-sleep) half; a raised HR alone must not promote wake.
            let awakeCardiac0 = 0.8 * zHRVValue + 0.4 * zHRValue
            let awakeCardiac = motionQuiescent(feature) ? min(0.0, awakeCardiac0) : awakeCardiac0
            var emission: [String: Double] = [
                "deep": -1.1 * zHRVValue - 0.5 * zMoveValue - gate + baseLogPrior["deep"]!,
                "rem": 0.6 * zHRVValue - 0.6 * zMoveValue + 0.4 * zHRValue + baseLogPrior["rem"]!,
                "light": baseLogPrior["light"]!,
                "awake": 1.0 * zMoveValue + awakeCardiac + baseLogPrior["awake"]!,
            ]
            // Guard DISABLED here (`.infinity` ⇒ remLatencyGuard = 0); pass 2 adds it once onset is known.
            let prior = cyclePrior(feature.clock, .infinity)
            for stage in stageNames { emission[stage]! += prior[stage]! }
            if feature.jerkMax > feature.jerkScale * jerkFloorGateMult {
                emission["awake"]! += motionGateBoost
            }
            if let resp = feature.respReg {
                let z = zResp(resp)
                emission["deep"]! += respWeight * z
                emission["rem"]! -= respWeight * z
            }
            sequence.append(emission)
        }

        // PASS 1 — stage without the REM-latency guard purely to locate sleep onset.
        let provisional = viterbi(sequence)
        // Origin for the guard: the centre of the first sustained-sleep epoch, in the same
        // window-relative minutes `features` stamped on every epoch. No sustained run → 0.0.
        let originMin = sustainedSleepOnset(provisional).map { features[$0].minutesSinceOnset } ?? 0.0

        // PASS 2 — apply the guard against minutes since THAT onset and re-run the lattice.
        for index in features.indices {
            sequence[index]["rem"]! -= remLatencyGuard(features[index].minutesSinceOnset - originMin)
        }
        return viterbi(sequence)
    }
}
