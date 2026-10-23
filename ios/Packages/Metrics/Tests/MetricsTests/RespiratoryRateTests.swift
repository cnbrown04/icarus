import Foundation
import Testing
@testable import Metrics

@Suite("RespiratoryRate (RSA from R-R, OpenStrap rsaRespRate)")
struct RespiratoryRateTests {
    /// Beats from integrating a modulated R-R: rr(t) = baseMs + amplitudeMs * sin(2 pi f t) + noise, with
    /// t the running clock. Every ectopy-th interval is shortened to 60 % and the next lengthened to 140 %.
    /// Timestamps are the cumulative clock, so the series is contiguous.
    private func rsaBeats(
        brpm: Double,
        seconds: Double,
        baseMs: Double = 1000,
        amplitudeMs: Double = 40,
        noiseMs: Double = 0,
        ectopyEvery: Int? = nil,
        startMs: Int64 = 0,
        seed: UInt64 = 1
    ) -> [RRSample] {
        var noise = SeededNoise(seed: seed)
        let f = brpm / 60
        var rr: [Double] = []
        var t = 0.0
        while t < seconds {
            let value = baseMs + amplitudeMs * sin(2 * Double.pi * f * t) + noiseMs * noise.uniform()
            rr.append(value)
            t += value / 1000
        }
        if let every = ectopyEvery {
            for k in stride(from: every, to: rr.count - 1, by: every) {
                rr[k] *= 0.6
                rr[k + 1] *= 1.4
            }
        }
        var clock = Double(startMs)
        return rr.map { value in
            clock += value
            return RRSample(tsMs: Int64(clock.rounded()), rrMs: value)
        }
    }

    /// Adds `gapSec` to every timestamp from index `at` on, as a dropout removes the beats in between.
    private func withGap(_ beats: [RRSample], at index: Int, gapSec: Double) -> [RRSample] {
        beats.enumerated().map { i, beat in
            i >= index ? RRSample(tsMs: beat.tsMs + Int64(gapSec * 1000), rrMs: beat.rrMs) : beat
        }
    }

    // MARK: - Window estimate

    @Test func recoversKnownRespiratoryRates() throws {
        for truth in [12.0, 15.0, 18.0] {
            let beats = rsaBeats(brpm: truth, seconds: 1800)
            let estimate = try #require(RespiratoryRate.windowEstimate(beats), "no estimate at \(truth)")
            #expect(abs(estimate.brpm - truth) <= 1, "truth \(truth), estimated \(estimate.brpm)")
            #expect(abs(estimate.brpm - estimate.peakHz * 60) < 1e-9)
            #expect(estimate.consensus >= 0.5)
        }
    }

    @Test func robustToNoiseAndEctopicBeats() throws {
        let beats = rsaBeats(brpm: 15, seconds: 1800, noiseMs: 20, ectopyEvery: 60)
        let estimate = try #require(RespiratoryRate.windowEstimate(beats))
        #expect(abs(estimate.brpm - 15) <= 1, "estimated \(estimate.brpm)")
    }

    @Test func dropoutInTheMiddleDoesNotCreateABogusRate() throws {
        let beats = rsaBeats(brpm: 15, seconds: 1200)
        let gapped = withGap(beats, at: beats.count / 2, gapSec: 60)

        // The gap must split the series into two runs, never one continuous tachogram.
        #expect(RespiratoryRate.contiguousRuns(RespiratoryRate.timeOrdered(gapped)).count == 2)

        let estimate = try #require(RespiratoryRate.windowEstimate(gapped))
        #expect(abs(estimate.brpm - 15) <= 1, "estimated \(estimate.brpm)")
    }

    @Test func tooShortInputIsNil() {
        #expect(RespiratoryRate.windowEstimate([]) == nil)
        #expect(RespiratoryRate.windowEstimate(rsaBeats(brpm: 15, seconds: 19)) == nil)
        // About 40 s of beats: no sub-window reaches the 60 s minimum.
        #expect(RespiratoryRate.windowEstimate(rsaBeats(brpm: 15, seconds: 40)) == nil)
    }

    @Test func unmodulatedRRHasNoRate() {
        // A constant R-R has no variance, so there is no spectrum at all.
        #expect(RespiratoryRate.windowEstimate(rsaBeats(brpm: 15, seconds: 1200, amplitudeMs: 0)) == nil)
    }

    @Test func noiseWithoutRSAIsWithheld() {
        // Pure beat-to-beat noise with no breathing modulation: the sub-windows must not agree.
        let beats = rsaBeats(brpm: 15, seconds: 1800, amplitudeMs: 0, noiseMs: 60)
        #expect(RespiratoryRate.windowEstimate(beats) == nil)
    }

    @Test func slowSleepingHeartRateWithholdsTheRate() {
        // Base R-R 1400 ms (43 bpm): the beat-rate Nyquist is 0.357 Hz, below the 0.40 Hz HF band, so a
        // 15 breaths/min modulation could alias. OpenStrap withholds rather than guess.
        #expect(RespiratoryRate.windowEstimate(rsaBeats(brpm: 15, seconds: 1800, baseMs: 1400)) == nil)
    }

    @Test func heavyArtefactShareIsWithheld() {
        // Every other interval ectopic: about half the beats are rejected, above the 30 % gate.
        let beats = rsaBeats(brpm: 15, seconds: 1800, ectopyEvery: 2)
        #expect(RespiratoryRate.windowEstimate(beats) == nil)
    }

    // MARK: - Gap handling

    @Test func contiguousRunsSplitOnlyOnRealGaps() {
        let steady = [
            RRSample(tsMs: 0, rrMs: 1000),
            RRSample(tsMs: 1_000, rrMs: 1000),
            // Two beats stamped in one record: equal timestamps never split.
            RRSample(tsMs: 2_000, rrMs: 900),
            RRSample(tsMs: 2_000, rrMs: 900),
            RRSample(tsMs: 3_000, rrMs: 1000),
        ]
        #expect(RespiratoryRate.contiguousRuns(steady).count == 1)

        // Wall step 10 s against a 1 s interval: a 9 s hole.
        let holed = steady + [RRSample(tsMs: 13_000, rrMs: 1000)]
        #expect(RespiratoryRate.contiguousRuns(holed).count == 2)

        // A 2 s residual is inside the 3 s tolerance and stays one run.
        let slight = [RRSample(tsMs: 0, rrMs: 1000), RRSample(tsMs: 3_000, rrMs: 1000)]
        #expect(RespiratoryRate.contiguousRuns(slight).count == 1)
    }

    @Test func equalTimestampsKeepInputOrder() {
        let packed = [
            RRSample(tsMs: 5_000, rrMs: 800),
            RRSample(tsMs: 5_000, rrMs: 900),
            RRSample(tsMs: 4_000, rrMs: 1000),
        ]
        let ordered = RespiratoryRate.timeOrdered(packed)
        #expect(ordered.map(\.rrMs) == [1000, 800, 900])
    }

    // MARK: - Night estimate

    @Test func nightEstimateIsMedianOfWindows() throws {
        // Two hours at 14 breaths/min with a ten-minute dropout after the first hour.
        let first = rsaBeats(brpm: 14, seconds: 3600)
        let second = rsaBeats(brpm: 14, seconds: 3600, startMs: 3_600_000 + 600_000)
        let night = try #require(RespiratoryRate.nightEstimate(first + second))
        #expect(abs(night.brpm - 14) <= 1, "estimated \(night.brpm)")
        #expect(night.windowsEstimated >= 3)
        #expect(night.coverage >= 0.5)
    }

    @Test func nightWithLowCoverageIsNil() {
        // Beats in the first 30 minutes and again two hours later: 2 of 5 windows have an estimate.
        let early = rsaBeats(brpm: 14, seconds: 1800)
        let late = rsaBeats(brpm: 14, seconds: 1800, startMs: 7_200_000)
        #expect(RespiratoryRate.nightEstimate(early + late) == nil)
    }

    @Test func emptyNightIsNil() {
        #expect(RespiratoryRate.nightEstimate([]) == nil)
    }
}

/// Deterministic uniform noise in [-1, 1) so the tests are reproducible.
private struct SeededNoise {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func uniform() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / Double(UInt64(1) << 53) * 2 - 1
    }
}
