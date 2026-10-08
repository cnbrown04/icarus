import Testing
@testable import Metrics

@Suite("FiveMinuteWindows (PLAN.md 8.2 step 3, 8.3)")
struct FiveMinuteWindowsTests {
    /// `count` intervals, one per second from `start`. `value(i)` gives the i-th interval in ms.
    private func rrSeries(_ count: Int, start: Int64 = 0, _ value: (Int) -> Double) -> [RRSample] {
        (0..<count).map { RRSample(tsMs: start + Int64($0) * 1_000, rrMs: value($0)) }
    }

    @Test func validityBoundaryIsExactlySixtyPercent() {
        // 225 intervals of 800 ms sum to 180 000 ms = 0.6 * 300 s. The window is valid.
        let valid = FiveMinuteWindows.build(samples: [], rr: rrSeries(225) { _ in 800 }, range: 0..<300_000)
        #expect(valid.count == 1)
        #expect(valid[0].valid)
        #expect(valid[0].rrSumMs == 180_000)

        // 224 intervals sum to 179 200 ms, which is below the bound. HRV is null.
        let invalid = FiveMinuteWindows.build(samples: [], rr: rrSeries(224) { _ in 800 }, range: 0..<300_000)
        #expect(!invalid[0].valid)
        #expect(invalid[0].rmssd == nil)
        #expect(invalid[0].sdnn == nil)
        #expect(invalid[0].lnRmssd == nil)
        #expect(invalid[0].baevskySqrt == nil)
    }

    @Test func alternatingSeriesHasHandComputedHRV() throws {
        // 226 intervals alternating 790 and 810 sum to 113 * 790 + 113 * 810 = 180 800 ms. The window is valid.
        // Each difference is +20 or -20, so the squares sum to 225 * 400 and RMSSD = sqrt(90000 / 225) = 20.
        // Mean is 800 with deviations of +-10. SDNN = sqrt(226 * 100 / 225) = 10.02220.
        // lnRMSSD = ln(20) = 2.995732.
        let rr = rrSeries(226) { $0 % 2 == 0 ? 790 : 810 }
        let window = try #require(FiveMinuteWindows.build(samples: [], rr: rr, range: 0..<300_000).first)
        #expect(abs((window.rmssd ?? -1) - 20) < 1e-9)
        #expect(abs((window.sdnn ?? -1) - 10.022197585581939) < 1e-9)
        #expect(abs((window.lnRmssd ?? -1) - 2.995732273553991) < 1e-9)
    }

    @Test func hrMeanExcludesNotDetectedAndWindowsAlignToFiveMinutes() {
        // 299 999 ms is in window 0. 300 000 ms starts window 300 000.
        // Window 0 has one sample at 60 bpm. Window 300 000 has only a notDetected sample, so its mean is nil.
        let samples = [
            HeartRateSample(tsMs: 299_999, bpm: 60),
            HeartRateSample(tsMs: 300_000, bpm: 70, contact: .notDetected),
        ]
        let windows = FiveMinuteWindows.build(samples: samples, rr: [], range: 0..<600_000)
        #expect(windows.map(\.startMs) == [0, 300_000])
        #expect(windows[0].hrMean == 60)
        #expect(windows[1].hrMean == nil)
    }

    @Test func rangeSelectsWindowsByStart() {
        // The first aligned start at or after 1 ms is 300 000. That is the only start below 300 001.
        let windows = FiveMinuteWindows.build(samples: [], rr: [], range: 1..<300_001)
        #expect(windows.map(\.startMs) == [300_000])
    }
}
