import Foundation

/// Sleep/wake detection: which spans of the strap's continuous record were sleep.
///
/// The strap records around the clock (CONTEXT.md lesson 1), so "the band was worn and the data is
/// contiguous" says nothing about sleep. That was the old `SleepDeriver` rule, and it turned a whole
/// worn day that touched 21:00–06:00 into one 20-hour "night". This is a port of NOOP's Stage 0
/// (ryanbr/noop `StrandAnalytics/SleepStager.swift`, `detectSleep`), the same gravity-stillness spine
/// OpenStrap's analytics builds its sleep window on (van Hees: the sleep period is sustained wrist
/// immobility, corroborated by heart rate):
///
/// 1. Spine: a record is "still" when its gravity vector moved < 0.01 g since the previous record; a
///    record is "sleep" when ≥ 70 % of the records in a centred 15-minute window are still.
/// 2. Runs: consecutive records of the same class, broken by a class change or a > 20-minute data
///    gap; runs shorter than 15 minutes are absorbed into their neighbours.
/// 3. Bridging (NOOP #308/#1657/#1937): when the record is gappy, or every sleep run is too short
///    on its own, two sleep runs split by ≤ 90 minutes (at most one short active run) are stitched
///    when heart rate across the split stays in the sleep band.
/// 4. Gates per sleep run: longer than 60 minutes; at most 16 hours (a longer "still" block is a
///    clock artefact, NOOP H4); median HR ≤ 1.05 × the surrounding 24 h median (1.30 when the wrist
///    was deeply motionless — an elevated-but-flat HR is not wakefulness); not mostly off-wrist.
/// 5. Night assembly: accepted runs ≤ 90 minutes apart, with at most an hour of movement and
///    near-sleeping HR in between, are one night with an awakening inside it (NOOP's
///    night-continuation chain, held to the bridge's active-time cap and a tighter HR test).
/// 6. Daytime guard (NOOP #90): a window centred 11:00–20:00 local that also began then is a nap
///    only when it lasts ≥ 90 minutes and its resting HR dips ≤ 0.95 × the baseline; sedentary
///    stillness (a desk, a sofa) does not dip.
/// 7. Main sleep (van Hees: the sleep period is the single longest block): per noon-to-noon local
///    day only the longest non-daytime window is kept. A still evening on the sofa before bed
///    passes the HR gate (resting HR is near sleeping HR) but is not the night.
///
/// Deliberate deviation from NOOP: missing records are not evidence of anything. NOOP's off-wrist
/// proxy counts every long HR gap as off-wrist; here a span with no records at all (a drain that
/// never reached the store) is unknown and ignored, and only records that are present but off-wrist
/// count toward the off-wrist fraction.
///
/// Honest limit: this detects a REST window from motion + heart rate, not PSG sleep. Onset/offset
/// are the bounds of sustained wrist stillness.
public enum SleepDetector {
    // MARK: Stage 0 constants (NOOP sleep.py values)

    /// Per-record gravity change (g) at or below which the record is "still".
    public static let gravityStillThresholdG = 0.01
    /// Rolling stillness window, in seconds of the median record spacing.
    public static let stillWindowSeconds = 15.0 * 60
    /// Fraction of still records in the window that makes its centre "sleep".
    public static let stillFraction = 0.70
    /// A data gap longer than this always breaks a run.
    public static let maxGapSeconds: Int64 = 20 * 60
    /// Runs shorter than this are absorbed into their neighbours.
    public static let mergeSeconds: Int64 = 15 * 60
    /// A sleep run must be longer than this to count.
    public static let minSleepSeconds: Int64 = 60 * 60
    /// A single sleep window longer than this is dropped as a clock artefact (NOOP H4).
    public static let maxSleepSeconds: Int64 = 16 * 60 * 60
    /// Smallest rolling window, in records.
    static let minWindowRecords = 3

    // MARK: Heart-rate gates

    /// A run is HR-confirmed when its median HR is ≤ baseline × this.
    public static let hrSleepBaselineMult = 1.05
    /// The widened band for a deeply motionless run (NOOP motion-corroborated wake).
    public static let quiescentHRSleepMult = 1.30
    /// Below this many HR samples a run is not HR-checked (gravity is trusted).
    public static let hrRefineMinSamples = 30
    /// The HR baseline is the median on-wrist HR within this distance of the run's centre: one day
    /// of context, so the baseline does not depend on how much history a derivation happened to read.
    public static let baselineHalfWindowSeconds: Int64 = 12 * 60 * 60

    // MARK: Bridging and night assembly

    /// Two sleep runs split by at most this are stitched when HR stays in the sleep band.
    public static let bridgeGapSeconds: Int64 = 90 * 60
    /// The longest single active run a bridge may absorb.
    public static let bridgeActiveMaxSeconds: Int64 = 30 * 60
    /// The same bound when HR across the whole split is in the sleep band.
    public static let bridgeActiveMaxInBandSeconds: Int64 = 60 * 60
    /// Accepted windows this close, with sleep-level HR between them, are one night.
    public static let nightContinuationGapSeconds: Int64 = 90 * 60
    /// HR during a within-night awakening may rise at most this much over the sleeping median.
    public static let awakeningHRMult = 1.10

    // MARK: Daytime guard

    /// Local hours [start, end) that count as daytime.
    public static let daytimeStartHour = 11
    public static let daytimeEndHour = 20
    /// A daytime nap must last at least this long.
    public static let daytimeMinSleepSeconds: Int64 = 90 * 60
    /// A daytime nap's resting HR must be ≤ baseline × this.
    public static let daytimeRestingHRMult = 0.95

    // MARK: Resting HR

    /// Width of a resting-HR bin, in seconds (NOOP sessionRestingHR uses 5-minute bins).
    static let restingBinSeconds: Int64 = 5 * 60
    /// A bin must hold this many samples to win the resting-HR floor (NOOP rhrMinBinSamples).
    public static let restingBinMinSamples = 5

    // MARK: Off-wrist

    /// Off-wrist accounting bin.
    static let offWristBinSeconds: Int64 = 5 * 60
    /// A bin is off-wrist when fewer than this fraction of its records are on-wrist with a valid HR.
    static let offWristBinOnFraction = 0.2
    /// A window whose measured bins are at least this fraction off-wrist is dropped.
    public static let maxOffWristFraction = 0.5

    // MARK: Motion quiescence (NOOP runIsDeeplyQuiescent)

    static let quiescentPostureVarG2 = 0.05
    static let quiescentStableFraction = 0.90
    static let quiescentMinStableMinutes = 20

    /// Physiological bpm range, matching the ingest gate (PLAN.md 7.3).
    static let bpmRange = 20.0...250.0

    /// One detected sleep window, unix seconds, both ends inclusive of a record.
    public struct Window: Sendable, Equatable {
        public let startUnix: Int64
        public let endUnix: Int64
        /// True for a daytime nap that passed the daytime guard; false for the night's main sleep.
        public let isNap: Bool

        public init(startUnix: Int64, endUnix: Int64, isNap: Bool) {
            self.startUnix = startUnix
            self.endUnix = endUnix
            self.isNap = isNap
        }
    }

    struct Gravity {
        let ts: Int64
        let x: Double
        let y: Double
        let z: Double
    }

    struct HRPoint {
        let ts: Int64
        let bpm: Double
    }

    struct Period {
        var isSleep: Bool
        var start: Int64
        var end: Int64

        var duration: Int64 { end - start }
    }

    /// Detects sleep windows in `records`. Order does not matter; duplicate timestamps keep the first.
    /// Records without gravity cannot be classified and only contribute heart rate.
    public static func detect(_ records: [SleepRecord], in timeZone: TimeZone) -> [Window] {
        let sorted = deduplicatedSorted(records)
        let grav = sorted.compactMap { record -> Gravity? in
            guard let g = record.gravity else { return nil }
            return Gravity(ts: record.unixSeconds, x: g.x, y: g.y, z: g.z)
        }
        guard grav.count >= 2 else { return [] }
        let hr = sorted.compactMap { record -> HRPoint? in
            guard record.skinContact, let bpm = record.bpm, bpmRange.contains(bpm) else { return nil }
            return HRPoint(ts: record.unixSeconds, bpm: bpm)
        }
        let baselines = BaselineCache(hr: hr)

        // 1-2. Stillness spine and runs.
        let flags = classifyStill(grav)
        var runs = mergePeriods(buildRuns(grav, flags))

        // 3. Bridge fragmented nights. NOOP enables the bridge for sparse gravity or a night whose
        // runs are each too short; a stored record with drain gaps is "sparse" in NOOP's terms.
        let sleepSpans = runs.filter(\.isSleep).map(\.duration)
        let fragmentedToNothing = sleepSpans.count >= 2
            && !sleepSpans.contains { $0 > minSleepSeconds }
            && sleepSpans.reduce(0, +) >= minSleepSeconds
        if largestGap(grav) > maxGapSeconds || fragmentedToNothing {
            runs = bridge(runs, hr: hr, baselines: baselines)
        }

        // 4. Per-run gates.
        let accepted = runs.filter { run in
            guard run.isSleep, run.duration > minSleepSeconds, run.duration <= maxSleepSeconds else {
                return false
            }
            guard confirmSleepWithHR(run, hr: hr, grav: grav, baseline: baselines.at(center(run))) else {
                return false
            }
            return offWristFraction(run, records: sorted) < maxOffWristFraction
        }

        // 5. Night assembly.
        var windows: [Period] = []
        for run in accepted {
            if let last = windows.last,
               run.start - last.end <= nightContinuationGapSeconds,
               run.end - last.start <= maxSleepSeconds,
               activeSeconds(between: last.end, and: run.start, runs: runs) <= bridgeActiveMaxInBandSeconds,
               awakeningStaysRestful(between: last, and: run, hr: hr) {
                windows[windows.count - 1].end = run.end
            } else {
                windows.append(run)
            }
        }

        // 6. Daytime guard.
        var kept: [Window] = []
        for window in windows {
            let daytime = isDaytime(center(window), in: timeZone) && isDaytime(window.start, in: timeZone)
            if daytime {
                guard window.duration >= daytimeMinSleepSeconds,
                      let resting = restingHR(window, hr: hr),
                      let baseline = baselines.at(center(window)),
                      resting <= baseline * daytimeRestingHRMult
                else { continue }
            }
            kept.append(Window(startUnix: window.start, endUnix: window.end, isNap: daytime))
        }

        // 7. One main sleep per noon-to-noon local day: the longest non-nap window.
        var longest: [LocalDay: Window] = [:]
        for window in kept where !window.isNap {
            let day = sleepDay(of: window, in: timeZone)
            if let current = longest[day],
               current.endUnix - current.startUnix >= window.endUnix - window.startUnix {
                continue
            }
            longest[day] = window
        }
        return kept.filter { window in
            window.isNap || longest[sleepDay(of: window, in: timeZone)] == window
        }
    }

    // MARK: Spine

    static func deduplicatedSorted(_ records: [SleepRecord]) -> [SleepRecord] {
        var seen = Set<Int64>()
        var unique: [SleepRecord] = []
        unique.reserveCapacity(records.count)
        for record in records where seen.insert(record.unixSeconds).inserted {
            unique.append(record)
        }
        return unique.sorted { $0.unixSeconds < $1.unixSeconds }
    }

    /// Median spacing between consecutive records, restricted to (0, 300) s; 60 s when unknown.
    static func medianIntervalSeconds(_ grav: [Gravity]) -> Double {
        var gaps: [Double] = []
        gaps.reserveCapacity(grav.count)
        for index in 1..<grav.count {
            let gap = Double(grav[index].ts - grav[index - 1].ts)
            if gap > 0, gap < 300 { gaps.append(gap) }
        }
        guard !gaps.isEmpty else { return 60 }
        gaps.sort()
        return max(gaps[gaps.count / 2], 1)
    }

    static func largestGap(_ grav: [Gravity]) -> Int64 {
        var largest: Int64 = 0
        for index in 1..<grav.count {
            largest = max(largest, grav[index].ts - grav[index - 1].ts)
        }
        return largest
    }

    /// Per-record sleep flags from a centred rolling fraction of still records (NOOP classifyStill).
    static func classifyStill(_ grav: [Gravity]) -> [Bool] {
        let n = grav.count
        let window = max(minWindowRecords, Int(stillWindowSeconds / medianIntervalSeconds(grav)))
        let half = window / 2
        // stillPrefix[i] = still records among [0, i); the first record has delta 0 (still).
        var stillPrefix = [Int](repeating: 0, count: n + 1)
        for index in 0..<n {
            var still = true
            if index > 0 {
                let a = grav[index - 1], b = grav[index]
                let dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z
                still = (dx * dx + dy * dy + dz * dz).squareRoot() < gravityStillThresholdG
            }
            stillPrefix[index + 1] = stillPrefix[index] + (still ? 1 : 0)
        }
        return (0..<n).map { index in
            let lo = max(0, index - half)
            let hi = min(n, index + half + 1)
            return Double(stillPrefix[hi] - stillPrefix[lo]) / Double(hi - lo) >= stillFraction
        }
    }

    /// Contiguous same-class runs, broken by a class change or a data gap over `maxGapSeconds`.
    static func buildRuns(_ grav: [Gravity], _ flags: [Bool]) -> [Period] {
        var periods: [Period] = []
        var runStart = 0
        for index in 1...grav.count {
            let close = index == grav.count
                || flags[index] != flags[runStart]
                || grav[index].ts - grav[index - 1].ts > maxGapSeconds
            if close {
                periods.append(Period(isSleep: flags[runStart], start: grav[runStart].ts, end: grav[index - 1].ts))
                runStart = index
            }
        }
        return periods
    }

    /// Absorbs runs shorter than `mergeSeconds` into their neighbours (NOOP mergePeriods).
    static func mergePeriods(_ periods: [Period]) -> [Period] {
        var pending = periods
        var merged: [Period] = []
        var index = 0
        while index < pending.count {
            let current = pending[index]
            guard current.duration < mergeSeconds else {
                merged.append(current)
                index += 1
                continue
            }
            let hasPrev = index > 0 && !merged.isEmpty
            let hasNext = index + 1 < pending.count
            if hasPrev, hasNext, pending[index - 1].isSleep == pending[index + 1].isSleep {
                let prev = merged.removeLast()
                merged.append(Period(isSleep: prev.isSleep, start: prev.start, end: pending[index + 1].end))
                index += 2
            } else if hasNext {
                pending[index + 1].start = current.start
                index += 1
            } else if hasPrev {
                merged[merged.count - 1].end = current.end
                index += 1
            } else {
                index += 1
            }
        }
        return merged
    }

    /// Stitches sleep runs split by a bare gap or one short active run when HR stays in the sleep
    /// band across the split (NOOP bridgeSparseSleep).
    static func bridge(_ periods: [Period], hr: [HRPoint], baselines: BaselineCache) -> [Period] {
        var out: [Period] = []
        func consider(_ left: Period, _ right: Period, activeSeconds: Int64, activeMax: Int64, activeMaxInBand: Int64) -> Bool {
            let gap = right.start - left.end
            guard gap >= 0, gap <= bridgeGapSeconds else { return false }
            let inBand = hrSleepBandAcross(left.end, right.start, hr: hr, baseline: baselines.at(left.end))
            let cap = inBand ? max(activeMax, activeMaxInBand) : activeMax
            return activeSeconds <= cap && inBand
        }
        for period in periods {
            if period.isSleep {
                if let last = out.last, last.isSleep,
                   consider(last, period, activeSeconds: 0, activeMax: 0, activeMaxInBand: 0) {
                    out[out.count - 1].end = period.end
                    continue
                }
                if out.count >= 2, let last = out.last, !last.isSleep, out[out.count - 2].isSleep,
                   consider(out[out.count - 2], period, activeSeconds: last.duration,
                            activeMax: bridgeActiveMaxSeconds, activeMaxInBand: bridgeActiveMaxInBandSeconds) {
                    out.removeLast()
                    out[out.count - 1].end = period.end
                    continue
                }
            }
            out.append(period)
        }
        return out
    }

    // MARK: Heart rate

    /// Median on-wrist HR within ±`baselineHalfWindowSeconds` of a time, cached per hour.
    final class BaselineCache {
        private let hr: [HRPoint]
        private var cache: [Int64: Double?] = [:]

        init(hr: [HRPoint]) {
            self.hr = hr
        }

        func at(_ ts: Int64) -> Double? {
            let hour = ts / 3600
            if let cached = cache[hour] { return cached }
            let center = hour * 3600 + 1800
            let values = SleepDetector.slice(hr, from: center - baselineHalfWindowSeconds, to: center + baselineHalfWindowSeconds)
                .map(\.bpm)
            let median = Statistics.median(values)
            cache[hour] = median
            return median
        }
    }

    /// HR points with ts in [from, to], by binary search on the sorted array.
    static func slice(_ hr: [HRPoint], from: Int64, to: Int64) -> ArraySlice<HRPoint> {
        let lo = lowerBound(hr, from)
        var hi = lowerBound(hr, to)
        while hi < hr.count, hr[hi].ts <= to { hi += 1 }
        return hr[lo..<max(lo, hi)]
    }

    private static func lowerBound(_ hr: [HRPoint], _ ts: Int64) -> Int {
        var lo = 0, hi = hr.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if hr[mid].ts < ts { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// True when the median HR in (a, b] is in the sleep band. No baseline or no HR there → false:
    /// nothing vouches for the split, so it stays a break.
    static func hrSleepBandAcross(_ a: Int64, _ b: Int64, hr: [HRPoint], baseline: Double?) -> Bool {
        guard let baseline else { return false }
        let values = slice(hr, from: a + 1, to: b).map(\.bpm)
        guard let median = Statistics.median(values) else { return false }
        return median <= baseline * hrSleepBaselineMult
    }

    /// Seconds of moving (non-sleep) runs inside (a, b). Missing records count as nothing.
    static func activeSeconds(between a: Int64, and b: Int64, runs: [Period]) -> Int64 {
        runs.reduce(0) { total, run in
            guard !run.isSleep else { return total }
            return total + max(0, min(run.end, b) - max(run.start, a))
        }
    }

    /// True when HR during the split between two accepted windows stays within
    /// `awakeningHRMult` of the calmer window's own median HR: a lie-awake spell inside one night.
    /// The day baseline is too loose here — an evening on the sofa followed by an hour up and about
    /// before bed sits under it too, and would chain into the night.
    static func awakeningStaysRestful(between left: Period, and right: Period, hr: [HRPoint]) -> Bool {
        let sleeping = [left, right].compactMap { Statistics.median(slice(hr, from: $0.start, to: $0.end).map(\.bpm)) }
        guard let calmer = sleeping.min(),
              let awake = Statistics.median(slice(hr, from: left.end + 1, to: right.start - 1).map(\.bpm))
        else { return false }
        return awake <= calmer * awakeningHRMult
    }

    /// NOOP confirmSleepWithHR: median HR over the run within the sleep band; the band widens for a
    /// deeply motionless run. Too little HR, or no baseline, trusts gravity.
    static func confirmSleepWithHR(_ run: Period, hr: [HRPoint], grav: [Gravity], baseline: Double?) -> Bool {
        guard let baseline else { return true }
        let values = slice(hr, from: run.start, to: run.end).map(\.bpm)
        guard values.count >= hrRefineMinSamples, let median = Statistics.median(values) else { return true }
        let mult = isDeeplyQuiescent(run, grav: grav) ? quiescentHRSleepMult : hrSleepBaselineMult
        return median <= baseline * mult
    }

    /// At least 90 % of the run's judgeable minutes have a near-constant wrist posture.
    static func isDeeplyQuiescent(_ run: Period, grav: [Gravity]) -> Bool {
        var byMinute: [Int64: [Gravity]] = [:]
        for g in grav where g.ts >= run.start && g.ts < run.end {
            byMinute[g.ts / 60, default: []].append(g)
        }
        var judged = 0, stable = 0
        for samples in byMinute.values where samples.count >= 2 {
            let n = Double(samples.count)
            let mx = samples.map(\.x).reduce(0, +) / n
            let my = samples.map(\.y).reduce(0, +) / n
            let mz = samples.map(\.z).reduce(0, +) / n
            let variance = samples.reduce(0.0) { sum, s in
                let dx = s.x - mx, dy = s.y - my, dz = s.z - mz
                return sum + dx * dx + dy * dy + dz * dz
            } / n
            judged += 1
            if variance < quiescentPostureVarG2 { stable += 1 }
        }
        guard judged >= quiescentMinStableMinutes else { return false }
        return Double(stable) / Double(judged) >= quiescentStableFraction
    }

    /// Lowest 5-minute bin mean HR with at least `restingBinMinSamples` samples (NOOP sessionRestingHR,
    /// #1943 gate). A one-sample bin at the edge of a wear gap cannot become the floor.
    static func restingHR(_ window: Period, hr: [HRPoint]) -> Double? {
        lowestBinMean(slice(hr, from: window.start, to: window.end), from: window.start, minSamples: restingBinMinSamples)
    }

    /// Session resting HR (NOOP sessionRestingHR). Gated first; if no bin qualifies, the lowest bin of
    /// any size; if there are no bins at all, nil. `points` must be sorted by time.
    static func sessionRestingHR(_ points: [HRPoint], startUnix: Int64, endUnix: Int64) -> Double? {
        let inside = slice(points, from: startUnix, to: endUnix)
        return lowestBinMean(inside, from: startUnix, minSamples: restingBinMinSamples)
            ?? lowestBinMean(inside, from: startUnix, minSamples: 1)
    }

    /// Lowest mean over 5-minute bins anchored at `start` that hold at least `minSamples` points.
    static func lowestBinMean(_ values: ArraySlice<HRPoint>, from start: Int64, minSamples: Int) -> Double? {
        var bins: [Int64: (sum: Double, count: Int)] = [:]
        for point in values {
            let bin = (point.ts - start) / restingBinSeconds
            bins[bin, default: (0, 0)].sum += point.bpm
            bins[bin, default: (0, 0)].count += 1
        }
        return bins.values.filter { $0.count >= minSamples }.map { $0.sum / Double($0.count) }.min()
    }

    // MARK: Off-wrist

    /// Fraction of the run's measured 5-minute bins that are off-wrist. Bins with no records are
    /// unknown (a drain gap), not off-wrist.
    static func offWristFraction(_ run: Period, records: [SleepRecord]) -> Double {
        var bins: [Int64: (on: Int, total: Int)] = [:]
        for record in records where record.unixSeconds >= run.start && record.unixSeconds <= run.end {
            let bin = (record.unixSeconds - run.start) / offWristBinSeconds
            let on = record.skinContact && (record.bpm.map { bpmRange.contains($0) } ?? false)
            bins[bin, default: (0, 0)].total += 1
            if on { bins[bin, default: (0, 0)].on += 1 }
        }
        guard !bins.isEmpty else { return 1 }
        let off = bins.values.filter { Double($0.on) / Double($0.total) < offWristBinOnFraction }.count
        return Double(off) / Double(bins.count)
    }

    // MARK: Local clock

    static func center(_ period: Period) -> Int64 {
        period.start + period.duration / 2
    }

    static func isDaytime(_ unix: Int64, in timeZone: TimeZone) -> Bool {
        let date = Date(timeIntervalSince1970: TimeInterval(unix))
        let local = Int64(timeZone.secondsFromGMT(for: date)) + unix
        let hour = Int(((local % 86_400) + 86_400) % 86_400 / 3600)
        return hour >= daytimeStartHour && hour < daytimeEndHour
    }

    /// The noon-to-noon local day a window belongs to: the local date 12 hours before its centre.
    static func sleepDay(of window: Window, in timeZone: TimeZone) -> LocalDay {
        let center = window.startUnix + (window.endUnix - window.startUnix) / 2
        return LocalTime.localDay(containing: (center - 12 * 3600) * 1000, in: timeZone)
    }
}
