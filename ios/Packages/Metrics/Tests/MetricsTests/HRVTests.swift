import Foundation
import Testing
@testable import Metrics

@Suite("HRV: RMSSD, SDNN, lnRMSSD")
struct HRVTests {
    @Test func rmssdHandComputed() {
        // Differences: 805 - 800 = 5, 800 - 805 = -5. Squares: 25, 25. Sum = 50.
        // N - 1 = 2. 50 / 2 = 25. sqrt(25) = 5.
        #expect(HRV.rmssd([800, 805, 800]) == 5)
    }

    @Test func rmssdWithOneDifferenceIsTheAbsoluteDifference() {
        // One difference of 30. (30^2) / 1 = 900. sqrt = 30.
        #expect(HRV.rmssd([800, 830]) == 30)
    }

    @Test func rmssdNeedsTwoValues() {
        #expect(HRV.rmssd([]) == nil)
        #expect(HRV.rmssd([800]) == nil)
    }

    @Test func sdnnHandComputed() {
        // Mean = (790 + 800 + 810) / 3 = 800. Deviations: -10, 0, 10. Squares sum = 200.
        // N - 1 = 2. 200 / 2 = 100. sqrt = 10.
        #expect(HRV.sdnn([790, 800, 810]) == 10)
    }

    @Test func sdnnUsesNMinusOneDenominator() throws {
        // Mean = 810. Deviations: -10, +10. Squares sum = 200.
        // With N - 1 = 1: 200 / 1 = 200, sqrt(200) = 14.142135623730951.
        // (Dividing by N would give 10, which is wrong here.)
        let value = try #require(HRV.sdnn([800, 820]))
        #expect(abs(value - 200.0.squareRoot()) < 1e-12)
    }

    @Test func sdnnNeedsTwoValues() {
        #expect(HRV.sdnn([800]) == nil)
    }

    @Test func lnRMSSDIsNaturalLogOfRMSSD() throws {
        // RMSSD = 5, so lnRMSSD = ln(5) = 1.6094379124341003.
        let value = try #require(HRV.lnRMSSD([800, 805, 800]))
        #expect(abs(value - 1.6094379124341003) < 1e-12)
    }

    @Test func lnRMSSDIsNilWhenRMSSDIsZero() {
        // Two equal intervals give RMSSD = 0, and ln(0) is undefined.
        #expect(HRV.lnRMSSD([800, 800]) == nil)
    }

    // MARK: Session windowed RMSSD

    /// Beats at `cadence` seconds from `start`, one interval per record, `rr(offset)` giving each interval.
    private func beats(from start: Int64, count: Int, cadence: Int64 = 1, rr: (Int64) -> Double) -> [(unixSeconds: Int64, rrMs: [Double])] {
        (0..<count).map { index in
            let ts = start + Int64(index) * cadence
            return (unixSeconds: ts, rrMs: [rr(ts)])
        }
    }

    @Test func windowedRMSSDDoesNotBridgeADataGap() throws {
        // Run A: 30 beats at 1000 ms. A 10 s gap. Run B: 30 beats at 1040 ms. Only differences inside a run
        // count, so every difference is 0 and the window's RMSSD is 0. A bridged difference would add 40 ms.
        let runA = beats(from: 0, count: 30) { _ in 1_000 }
        let runB = beats(from: 40, count: 30) { _ in 1_040 }
        #expect(HRV.windowedRMSSD(runA + runB, startUnix: 0) == 0)
    }

    @Test func windowedRMSSDNeedsTwentyDifferencesPerWindow() throws {
        // Window 0 (0-299 s): 21 beats alternating 1000 / 1080, which is 20 differences of 80 ms.
        // Window 1 (300-599 s): 20 beats alternating 1000 / 1040, which is 19 differences of 40 ms, so it is dropped.
        // Averaging it in would give 60. Keeping only window 0 gives 80.
        let window0 = beats(from: 0, count: 21) { ts in ts % 2 == 0 ? 1_000 : 1_080 }
        let window1 = beats(from: 300, count: 20) { ts in ts % 2 == 0 ? 1_000 : 1_040 }
        #expect(HRV.windowedRMSSD(window0 + window1, startUnix: 0) == 80)
    }

    @Test func windowedRMSSDIsTheMeanOfQualifyingWindows() throws {
        // Two full windows: 40 ms and 80 ms. The session value is their mean, 60.
        let window0 = beats(from: 0, count: 300) { ts in ts % 2 == 0 ? 1_000 : 1_040 }
        let window1 = beats(from: 300, count: 300) { ts in ts % 2 == 0 ? 1_000 : 1_080 }
        #expect(HRV.windowedRMSSD(window0 + window1, startUnix: 0) == 60)
    }

    @Test func windowedRMSSDAcceptsBeatsUpToTwoSecondsApart() throws {
        // One record every two seconds still chains: 150 beats in one window, so 149 differences of 40 ms.
        let chained = beats(from: 0, count: 150, cadence: 2) { ts in (ts / 2) % 2 == 0 ? 1_000 : 1_040 }
        #expect(HRV.windowedRMSSD(chained, startUnix: 0) == 40)
        // Three seconds apart breaks every link, so nothing qualifies.
        let spaced = beats(from: 0, count: 150, cadence: 3) { ts in (ts / 3) % 2 == 0 ? 1_000 : 1_040 }
        #expect(HRV.windowedRMSSD(spaced, startUnix: 0) == nil)
    }

    @Test func windowedRMSSDDropsRejectedBeatsAndTheirNeighbours() throws {
        // Beats 0-29 are 1 000 ms, beats 31-59 are 1 040 ms, and beat 30 is 1 900 ms. The median filter
        // rejects beat 30. Differencing beat 29 against beat 31 would add 40 ms; the split keeps both runs at 0.
        var stream = beats(from: 0, count: 60) { ts in ts < 30 ? 1_000 : 1_040 }
        stream[30].rrMs = [1_900]
        #expect(HRV.windowedRMSSD(stream, startUnix: 0) == 0)
    }

    @Test func windowedRMSSDIgnoresBeatsBeforeTheStart() throws {
        // Beats before `startUnix` are not in any window; the qualifying window is the one at 100 s.
        let early = beats(from: 0, count: 100) { _ in 500 }
        let session = beats(from: 100, count: 300) { ts in ts % 2 == 0 ? 1_000 : 1_040 }
        #expect(HRV.windowedRMSSD(early + session, startUnix: 100) == 40)
    }
}
