import Foundation

/// Respiratory rate (breaths/min) from R-R intervals, via respiratory sinus arrhythmia (RSA).
///
/// WHY FROM R-R. The strap's `resp_rate_raw` field is a constant (3073) on every record, so it
/// does not measure respiration. Breathing modulates beat-to-beat timing instead: heart rate rises
/// on inspiration and falls on expiration, so the R-R series carries a component at the breathing
/// frequency, and the peak of its spectrum is the breathing rate.
///
/// PORT. The estimator is OpenStrap `rsaRespRate` (`os-analytics/lib/src/onehz/respiration/resp_rate.dart`):
/// a Lomb-Scargle peak in the classic HF band on each sub-window, the median across sub-windows, an
/// agreement gate, and the medoid sub-window's rate reported. Beat timing follows OpenStrap `_beatTimes`
/// (`os-analytics/lib/src/onehz/foundations/rr_correction.dart`): the clock is a cumulative sum of R-R
/// inside a contiguous run and never crosses a dropout. The dropout threshold is NOOP's `rsaGapToleranceS`
/// (`noop/Packages/StrandAnalytics/Sources/StrandAnalytics/SleepStager.swift`, `respRateFromRR`).
/// Artefact rejection is `RRCleaner`.
///
/// This is an on-device estimate from heart-timing modulation. It is not a clinical respiration measurement.
public enum RespiratoryRate {
    /// Estimates outside this band are rejected, not clamped. OpenStrap `respLoHz`/`respHiHz`
    /// (0.1–0.5 Hz = 6–30 breaths/min). The RSA search band is narrower (see `searchLoHz`), so in
    /// practice the band bounds the output at 9–30 breaths/min.
    public static let plausibleRangeBrpm: ClosedRange<Double> = 6...30

    /// Lower edge of the RSA search, 0.15 Hz = 9 breaths/min. OpenStrap `rsaLoHz`, the classic HF band
    /// where the respiratory peak lives in the RR spectrum.
    static let searchLoHz = 0.15
    /// Upper edge of the classic HF band, 0.40 Hz = 24 breaths/min. OpenStrap `rsaHiHz`. The search
    /// runs up to each window's own ceiling (`ceilingHz`), not this value.
    static let searchHiHz = 0.40
    /// Highest respiratory frequency any estimate may claim, 0.5 Hz = 30 breaths/min. OpenStrap `respHiHz`.
    static let ceilingHz = 0.5

    /// Sub-window length for the Welch segmentation, seconds. OpenStrap `rsaSegmentSec`. Long enough
    /// that 1/T resolves the HF band (0.2 breaths/min), short enough that breathing is stationary inside it.
    static let subwindowSec = 300.0
    /// Shortest sub-window worth a spectrum, seconds. OpenStrap `rsaRespRate` (`segSec < 60`).
    static let minSubwindowSec = 60.0
    /// A beat whose wall-clock step exceeds its own R-R by more than this starts a new run, seconds.
    /// NOOP `rsaGapToleranceS`. Timestamps are whole seconds, so smaller residuals are quantisation.
    static let gapToleranceSec = 3.0
    /// Share of a sub-window that clean beats must cover (sum of kept R-R, not first-to-last span).
    /// OpenStrap `rsaRespRate` (`coveredSec < segSec * 0.8`).
    static let minSubwindowCoverage = 0.8
    /// Fewest beats a sub-window may hold. OpenStrap `rsaRespRate` (`k < 30`).
    static let minSubwindowBeats = 30
    /// Fewest kept beats a window may hold. OpenStrap `rsaRespRate` (`nnMs.length < 20`).
    static let minWindowBeats = 20
    /// Largest share of rejected beats a window may hold. OpenStrap `rsaRespRate` `maxArtifact` = 0.30.
    static let maxArtifactFraction = 0.30
    /// Sub-windows within this many breaths/min of the median count as agreeing. OpenStrap `tolBrpm`.
    static let consensusToleranceBrpm = 2.0
    /// Share of sub-windows that must agree. OpenStrap `minConsensus` = 0.5. It was calibrated against
    /// a shuffled-R-R surrogate, where agreement is 15–28 %, and real nights, where it is 52–85 %.
    static let minConsensus = 0.5
    /// Fewest usable sub-windows for a window estimate. OpenStrap `rsaRespRate` (`peaks.length < 3`).
    static let minUsableSubwindows = 3

    /// Night windows are this long, seconds. Each window gets its own estimate, and the night is the
    /// median of them. Thirty minutes is short enough that breathing is roughly stationary across it.
    /// OpenStrap `respiration.dart` reports a rate that drifts over a night (about 19 to 16 breaths/min).
    public static let nightWindowSec = 1800.0
    /// Fewest windows, as a share of the night's span, that must yield an estimate. Below it the night
    /// is withheld. The value is a choice of this port, not taken from the reference.
    public static let minNightCoverage = 0.5

    /// One window's estimate and the evidence behind it.
    public struct WindowEstimate: Sendable, Equatable {
        /// Breaths per minute, taken from the medoid sub-window (the one whose peak is closest to the
        /// median). `brpm == peakHz * 60`, so the three values come from one source.
        public let brpm: Double
        /// The medoid sub-window's spectral peak, Hz.
        public let peakHz: Double
        /// Sub-windows that produced a peak.
        public let usableSubwindows: Int
        /// Sub-windows tried, usable or not.
        public let subwindows: Int
        /// Share of usable sub-windows within `consensusToleranceBrpm` of the median.
        public let consensus: Double
    }

    /// The whole-night estimate: the median of the per-window estimates.
    public struct NightEstimate: Sendable, Equatable {
        /// Median of the windows' breaths/min.
        public let brpm: Double
        /// Windows that produced an estimate.
        public let windowsEstimated: Int
        /// Windows spanned by the input, including empty ones.
        public let windowsTotal: Int

        /// Share of spanned windows that produced an estimate.
        public var coverage: Double { Double(windowsEstimated) / Double(windowsTotal) }
    }

    /// Respiratory rate for one window of beats, or nil when the window cannot support one.
    ///
    /// `beats` is one window of R-R intervals with their receive timestamps, in any order. Beats that
    /// share a timestamp keep their input order, because the clock is a cumulative sum of R-R.
    /// Nil means: fewer than `minWindowBeats` kept beats, an artefact share above `maxArtifactFraction`,
    /// a beat rate too slow to resolve the HF band, no sub-window that passes the coverage and density
    /// gates, fewer than `minUsableSubwindows` peaks, or sub-windows that do not agree.
    public static func windowEstimate(_ beats: [RRSample]) -> WindowEstimate? {
        let ordered = timeOrdered(beats)
        let runs = contiguousRuns(ordered).map { cleanRun($0) }
        let kept = runs.reduce(0) { $0 + $1.nnMs.count }
        let rejected = ordered.count - kept
        guard kept >= minWindowBeats else { return nil }
        let artifactFraction = Double(rejected) / Double(ordered.count)
        guard artifactFraction <= maxArtifactFraction else { return nil }

        // Whole-window ceiling, from the median beat interval (gap-free by construction). A rate the
        // beat stream cannot resolve is withheld, not reported as an alias. OpenStrap `rsaCeilingHz`.
        let allNn = runs.flatMap(\.nnMs)
        guard let beatSec = Statistics.median(allNn).map({ $0 / 1000 }),
              ceilingHzFor(beatIntervalSec: beatSec) >= searchHiHz else { return nil }

        var peaksBrpm: [Double] = []
        var peaksHz: [Double] = []
        var tried = 0
        for run in runs {
            for segment in subwindows(of: run) {
                tried += 1
                if case .peak(let hz) = peakHz(in: segment) {
                    peaksHz.append(hz)
                    peaksBrpm.append(hz * 60)
                }
            }
        }
        let usable = peaksBrpm.count
        guard usable >= minUsableSubwindows, let medianBrpm = Statistics.median(peaksBrpm) else { return nil }

        let agreeing = peaksBrpm.filter { abs($0 - medianBrpm) <= consensusToleranceBrpm }.count
        let consensus = Double(agreeing) / Double(usable)
        guard consensus >= minConsensus else { return nil }

        // Medoid: the sub-window closest to the median. The first one wins a tie.
        var best = 0
        for i in peaksBrpm.indices where abs(peaksBrpm[i] - medianBrpm) < abs(peaksBrpm[best] - medianBrpm) {
            best = i
        }
        let brpm = peaksBrpm[best]
        guard plausibleRangeBrpm.contains(brpm) else { return nil }
        return WindowEstimate(
            brpm: brpm,
            peakHz: peaksHz[best],
            usableSubwindows: usable,
            subwindows: tried,
            consensus: consensus
        )
    }

    /// Whole-night respiratory rate: the median of per-window estimates over fixed `windowSec` windows.
    ///
    /// Windows are counted from the first beat. A window with no estimate still counts toward
    /// `windowsTotal`, so a long dropout lowers coverage. Nil when no window has an estimate, when the
    /// estimated share is below `minCoverage`, or when the median falls outside `plausibleRangeBrpm`.
    public static func nightEstimate(
        _ beats: [RRSample],
        windowSec: Double = nightWindowSec,
        minCoverage: Double = minNightCoverage
    ) -> NightEstimate? {
        guard let windows = nightWindows(beats, windowSec: windowSec) else { return nil }
        return nightEstimate(windows, minCoverage: minCoverage)
    }

    /// `nightEstimate` from windows `nightWindows` already produced, so a caller that keeps the windows does not
    /// compute the spectra twice.
    public static func nightEstimate(
        _ windows: (estimates: [(startMs: Int64, brpm: Double)], total: Int),
        minCoverage: Double = minNightCoverage
    ) -> NightEstimate? {
        let estimates = windows.estimates.map(\.brpm)
        let total = windows.total
        guard !estimates.isEmpty,
              Double(estimates.count) / Double(total) >= minCoverage,
              let brpm = Statistics.median(estimates),
              plausibleRangeBrpm.contains(brpm)
        else { return nil }
        return NightEstimate(brpm: brpm, windowsEstimated: estimates.count, windowsTotal: total)
    }

    /// The per-window estimates `nightEstimate` takes the median of, in time order, each stamped with its
    /// window's start (ms), and the number of windows the beats span. Windows count from `originMs`, or from the
    /// first beat when nil (a night). Nil without beats.
    public static func nightWindows(
        _ beats: [RRSample],
        windowSec: Double = nightWindowSec,
        originMs: Int64? = nil
    ) -> (estimates: [(startMs: Int64, brpm: Double)], total: Int)? {
        let ordered = timeOrdered(beats).filter { $0.tsMs >= (originMs ?? Int64.min) }
        guard let first = ordered.first?.tsMs, windowSec > 0 else { return nil }
        let origin = originMs ?? first

        var windows: [Int: [RRSample]] = [:]
        for beat in ordered {
            let index = Int(Double(beat.tsMs - origin) / 1000 / windowSec)
            windows[index, default: []].append(beat)
        }
        guard let lastIndex = windows.keys.max() else { return nil }

        var estimates: [(startMs: Int64, brpm: Double)] = []
        for index in windows.keys.sorted() {
            if let window = windowEstimate(windows[index] ?? []) {
                estimates.append((origin + Int64(Double(index) * windowSec * 1000), window.brpm))
            }
        }
        return (estimates, lastIndex + 1)
    }

    // MARK: - Beat timing

    /// A contiguous run of beats with its kept (RRCleaner-accepted) intervals.
    struct CleanRun {
        /// Kept beats' times on the R-R clock (cumulative sum), seconds, ascending. This is the clock the
        /// spectrum uses, because its precision is sub-second.
        let tSec: [Double]
        /// Kept beats' times on the wall clock (record timestamps), seconds from the run's first beat.
        /// Whole-second resolution, so it is used only to judge coverage, never for the spectrum.
        let wallSec: [Double]
        /// Kept beats' R-R, ms, index-aligned with `tSec`.
        let nnMs: [Double]
    }

    /// Orders beats by timestamp and keeps the input order for equal timestamps.
    ///
    /// Records carry several R-R values under one timestamp, and the clock depends on their order.
    /// Swift's `sort` is not documented as stable, so the index breaks ties. OpenStrap `respRateFromRR`
    /// makes the same stable-sort point (#823).
    static func timeOrdered(_ beats: [RRSample]) -> [RRSample] {
        beats.enumerated()
            .sorted { a, b in
                a.element.tsMs != b.element.tsMs ? a.element.tsMs < b.element.tsMs : a.offset < b.offset
            }
            .map(\.element)
    }

    /// Splits time-ordered beats wherever the wall clock outruns the beat by more than `gapToleranceSec`.
    ///
    /// A beat's wall step from its predecessor should equal its own R-R. A larger residual means beats
    /// the band never reported, so the cumulative sum would splice the two sides together. Equal
    /// timestamps (several R-R in one record) give a residual of zero or less and never split.
    /// NOOP `respRateFromRR` (`rsaGapToleranceS`) and OpenStrap `_beatTimes`.
    static func contiguousRuns(_ beats: [RRSample]) -> [[RRSample]] {
        var runs: [[RRSample]] = []
        var run: [RRSample] = []
        for (i, beat) in beats.enumerated() {
            if i > 0 {
                let wallStepSec = Double(beat.tsMs - beats[i - 1].tsMs) / 1000
                if wallStepSec - beat.rrMs / 1000 > gapToleranceSec {
                    runs.append(run)
                    run = []
                }
            }
            run.append(beat)
        }
        if !run.isEmpty { runs.append(run) }
        return runs
    }

    /// Runs RRCleaner over one run and places the kept beats on the run's clock.
    ///
    /// Rejected beats still advance the clock, because the time they span really passed. Only their
    /// values are dropped. OpenStrap `correctRr` makes the same choice (the clock advances for every
    /// interval, kept or dropped).
    static func cleanRun(_ run: [RRSample]) -> CleanRun {
        let flags = RRCleaner.acceptedFlags(run.map(\.rrMs))
        var tSec: [Double] = []
        var wallSec: [Double] = []
        var nnMs: [Double] = []
        var clock = 0.0
        let origin = run.first?.tsMs ?? 0
        for (i, beat) in run.enumerated() {
            if i > 0 { clock += beat.rrMs / 1000 }
            if flags[i] {
                tSec.append(clock)
                wallSec.append(Double(beat.tsMs - origin) / 1000)
                nnMs.append(beat.rrMs)
            }
        }
        return CleanRun(tSec: tSec, wallSec: wallSec, nnMs: nnMs)
    }

    // MARK: - Spectrum

    /// One sub-window of kept beats, on its run's clock.
    struct Segment {
        /// Nominal sub-window length, seconds. Coverage is judged against this, not the beats' span.
        let nominalSec: Double
        let tSec: [Double]
        let nnMs: [Double]
    }

    /// Welch-style sub-windows of one run: `subwindowSec` long (or half the run when the run is shorter
    /// than two of them), stepping by half their length. Windows are cut on the WALL clock, so a
    /// sub-window's coverage is measured against real elapsed time. A sub-window never crosses a dropout,
    /// because each run is contiguous. OpenStrap `rsaRespRate` (Welch segmentation).
    static func subwindows(of run: CleanRun) -> [Segment] {
        guard let first = run.wallSec.first, let last = run.wallSec.last else { return [] }
        let spanSec = last - first
        guard spanSec >= 2 * minSubwindowSec else { return [] }
        let segSec = spanSec < 2 * subwindowSec ? spanSec / 2 : subwindowSec
        guard segSec >= minSubwindowSec else { return [] }

        var segments: [Segment] = []
        var start = first
        while start + segSec <= last + 1e-9 {
            let lo = lowerBound(run.wallSec, start)
            let hi = lowerBound(run.wallSec, start + segSec)
            segments.append(Segment(
                nominalSec: segSec,
                tSec: Array(run.tSec[lo..<hi]),
                nnMs: Array(run.nnMs[lo..<hi])
            ))
            start += segSec / 2
        }
        return segments
    }

    enum SubwindowResult {
        case peak(Double)
        case unusable
    }

    /// The RSA peak of one sub-window, Hz, or `.unusable` for the four reasons OpenStrap counts:
    /// too little coverage, too few beats, a beat rate too slow for the HF band, or a peak at the
    /// search ceiling or no peak. OpenStrap `rsaRespRate`, per-sub-window loop.
    static func peakHz(in segment: Segment) -> SubwindowResult {
        // Covered time is the sum of kept R-R inside the sub-window's wall-clock span, not its beat count
        // or first-to-last beat: two beats at the edges with a three-minute hole between them must not pass
        // as a full sub-window. Summing R-R on the R-R clock would hide missing beats, because the clock
        // closes over them, which is why coverage is judged against the wall. OpenStrap `rsaRespRate`.
        let coveredSec = segment.nnMs.reduce(0, +) / 1000
        guard coveredSec >= minSubwindowCoverage * segment.nominalSec,
              segment.tSec.count >= minSubwindowBeats,
              let medianNn = Statistics.median(segment.nnMs)
        else { return .unusable }

        let hiHz = ceilingHzFor(beatIntervalSec: medianNn / 1000)
        guard hiHz >= searchHiHz else { return .unusable }

        // Oversample the frequency grid 4x the sub-window's own resolution (1/span). A finer grid only
        // re-reads the same bins. OpenStrap `rsaRespRate`.
        let span = segment.tSec.last! - segment.tSec.first!
        let gridCount = max(64, Int(ceil((hiHz - searchLoHz) * 4 * span)))
        let grid = frequencyGrid(lo: searchLoHz, hi: hiHz, count: gridCount)
        guard let power = lombScargle(t: segment.tSec, y: segment.nnMs, freqsHz: grid) else { return .unusable }

        var bestIndex = 0
        for i in power.indices where power[i] > power[bestIndex] {
            bestIndex = i
        }
        // A maximum within one grid step of either edge of the search band is not a respiratory peak. At the
        // ceiling the true rate is at or above what the sub-window can resolve, and reporting the edge would
        // publish the ceiling as a measurement (OpenStrap `rsaRespRate`, `pk >= segHi - step`). The floor
        // gets the mirror test, because a maximum pinned there is a slow trend leaking into the band (seen on
        // a real night: a sub-window at exactly 0.15 Hz). Neither edge is a rate.
        guard bestIndex >= 2, bestIndex <= gridCount - 3 else { return .unusable }
        return .peak(grid[bestIndex])
    }

    /// Highest respiratory frequency the beat stream can resolve, Hz. The tachogram is sampled once per
    /// beat, so its Nyquist is 0.5 / beat interval (DeBoer, Karemaker & Strackee 1984), capped at `ceilingHz`.
    /// OpenStrap `rsaCeilingHz`. The beat interval is the median of the NN values, never a time span, which
    /// missing beats would stretch.
    static func ceilingHzFor(beatIntervalSec: Double) -> Double {
        guard beatIntervalSec.isFinite, beatIntervalSec > 0 else { return ceilingHz }
        return min(0.5 / beatIntervalSec, ceilingHz)
    }

    /// Lomb-Scargle power at each frequency for unevenly sampled `y` at times `t` (seconds).
    ///
    /// Press & Rybicki (1989), with the τ time-shift correction. Port of OpenStrap `util.dart`
    /// `lombScargle`, periodogram `0.5·(term1+term2)`. The one-sided density factor `2Δt` is omitted because
    /// it is a single positive constant across the spectrum, so the peak's frequency does not change.
    static func lombScargle(t: [Double], y: [Double], freqsHz: [Double]) -> [Double]? {
        let n = t.count
        guard n >= 4, y.count == n, !freqsHz.isEmpty else { return nil }
        let mean = y.reduce(0, +) / Double(n)
        let centred = y.map { $0 - mean }
        let variance = centred.reduce(0) { $0 + $1 * $1 } / Double(n - 1)
        guard variance > 0, let tMin = t.min(), let tMax = t.max(), tMax > tMin else { return nil }

        var power: [Double] = []
        power.reserveCapacity(freqsHz.count)
        for f in freqsHz {
            let w = 2 * Double.pi * f
            if w == 0 {
                power.append(0)
                continue
            }
            var sin2 = 0.0
            var cos2 = 0.0
            for ti in t {
                sin2 += sin(2 * w * ti)
                cos2 += cos(2 * w * ti)
            }
            let tau = atan2(sin2, cos2) / (2 * w)

            var cNum = 0.0, cDen = 0.0, sNum = 0.0, sDen = 0.0
            for i in 0..<n {
                let arg = w * (t[i] - tau)
                let c = cos(arg)
                let s = sin(arg)
                cNum += centred[i] * c
                cDen += c * c
                sNum += centred[i] * s
                sDen += s * s
            }
            let term1 = cDen == 0 ? 0 : (cNum * cNum) / cDen
            let term2 = sDen == 0 ? 0 : (sNum * sNum) / sDen
            power.append(0.5 * (term1 + term2))
        }
        return power
    }

    /// `count` evenly spaced frequencies from `lo` to `hi`, inclusive. OpenStrap `util.dart` `freqGrid`.
    static func frequencyGrid(lo: Double, hi: Double, count: Int) -> [Double] {
        guard count > 1 else { return count == 1 ? [lo] : [] }
        let step = (hi - lo) / Double(count - 1)
        return (0..<count).map { lo + step * Double($0) }
    }

    /// First index whose value is at or above `v`. `a` must be ascending.
    static func lowerBound(_ a: [Double], _ v: Double) -> Int {
        var lo = 0
        var hi = a.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if a[mid] < v {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }
}
