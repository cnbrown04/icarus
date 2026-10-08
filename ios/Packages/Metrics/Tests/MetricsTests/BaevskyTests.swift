import Testing
@testable import Metrics

@Suite("Baevsky stress index (PLAN.md 8.3)")
struct BaevskyTests {
    @Test func handComputedFiveIntervals() throws {
        // 50 ms bins: 800 is in bin 16, 850 in bin 17, 900 in bin 18. Counts 2, 2, 1. Mode count 2.
        // AMo = 2 / 5 * 100 = 40 %.
        // Sorted [800, 800, 850, 850, 900], median 850 ms, so Mo = 0.85 s.
        // MxDMn = 900 - 800 = 100 ms = 0.1 s.
        // SI = 40 / (2 * 0.85 * 0.1) = 40 / 0.17 = 235.2941. sqrt(SI) = 15.33930.
        let rr: [Double] = [800, 850, 900, 850, 800]
        let si = try #require(Baevsky.stressIndex(rrMs: rr))
        #expect(abs(si - 40.0 / 0.17) < 1e-9)
        let root = try #require(Baevsky.sqrtStressIndex(rrMs: rr))
        #expect(abs(root - 15.339299776947408) < 1e-9)
    }

    @Test func modeBinHoldsThreeOfFour() throws {
        // 800, 825 and 849 are in bin [800, 850). 860 is in [850, 900). AMo = 3 / 4 * 100 = 75 %.
        // Sorted median = (825 + 849) / 2 = 837 ms, so Mo = 0.837 s. MxDMn = 0.06 s.
        // SI = 75 / (2 * 0.837 * 0.06) = 75 / 0.10044 = 746.7145.
        let si = try #require(Baevsky.stressIndex(rrMs: [800, 825, 849, 860]))
        #expect(abs(si - 75.0 / (2 * 0.837 * 0.06)) < 1e-9)
    }

    @Test func binsStartAtMultiplesOfFifty() throws {
        // 849.9 is in bin [800, 850). 850.0 is in bin [850, 900). Counts are 2 and 2, so AMo = 50 %.
        // Sorted median = (849.9 + 850) / 2 = 849.95 ms. MxDMn = 0.05 s.
        let si = try #require(Baevsky.stressIndex(rrMs: [800, 849.9, 850, 850]))
        #expect(abs(si - 50.0 / (2 * 0.84995 * 0.05)) < 1e-9)
    }

    @Test func equalIntervalsAndSingleIntervalAreNil() {
        // MxDMn is zero for equal intervals, so the index is undefined. One interval is not enough.
        #expect(Baevsky.stressIndex(rrMs: [800, 800]) == nil)
        #expect(Baevsky.stressIndex(rrMs: [800]) == nil)
        #expect(Baevsky.sqrtStressIndex(rrMs: []) == nil)
    }
}
