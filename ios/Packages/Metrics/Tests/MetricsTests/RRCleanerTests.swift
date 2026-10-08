import Testing
@testable import Metrics

@Suite("RRCleaner (PLAN.md 8.2 steps 1-2)")
struct RRCleanerTests {
    @Test func emptyInputGivesNoFlags() {
        #expect(RRCleaner.acceptedFlags([]).isEmpty)
    }

    @Test func rangeFilterRejectsBelow300AndAbove2000() {
        // 299 < 300 and 2001 > 2000 are rejected by range. 800, 801, 802 pass the median check.
        let flags = RRCleaner.acceptedFlags([800, 801, 299, 2001, 802])
        #expect(flags == [true, true, false, false, true])
    }

    @Test func rangeBoundariesAreInclusive() {
        #expect(RRCleaner.acceptedFlags([300]) == [true])
        #expect(RRCleaner.acceptedFlags([2000]) == [true])
    }

    @Test func nanIsRejected() {
        #expect(RRCleaner.acceptedFlags([.nan]) == [false])
    }

    @Test func medianDeviationAtExactly20PercentIsAccepted() {
        // Median of [800] is 800. 20% of 800 is 160.
        // 960 - 800 = 160, not greater than 160, so accepted.
        #expect(RRCleaner.acceptedFlags([800, 960]) == [true, true])
    }

    @Test func medianDeviationAbove20PercentIsRejected() {
        // 961 - 800 = 161 > 160, so rejected.
        #expect(RRCleaner.acceptedFlags([800, 961]) == [true, false])
    }

    @Test func rejectedIntervalsDoNotEnterTheMedianWindow() {
        // 1000 is rejected (|1000 - 800| = 200 > 160). If it were kept, the median of [800, 1000]
        // would be 900 and the second 1000 would pass (|100| <= 180). Since it is excluded,
        // the median stays 800 and the second 1000 is also rejected.
        #expect(RRCleaner.acceptedFlags([800, 1000, 1000]) == [true, false, false])
    }

    @Test func medianUsesPreviousAcceptedValuesOnly() {
        // Median of [800, 810, 790] = 800. 1000 is rejected; 805 is then checked against 800 and passes.
        #expect(RRCleaner.acceptedFlags([800, 810, 790, 1000, 805]) == [true, true, true, false, true])
    }
}
