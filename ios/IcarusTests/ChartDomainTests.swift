import Testing
@testable import Icarus

struct ChartDomainTests {
    @Test func snapsALineToFivesWithThreeUnitsOfRoom() {
        #expect(ChartDomain.line([68, 71]) == 65...75)
    }

    @Test func padsWideSpreadsByTenPercent() {
        // Spread 80, so 8 units of padding each side, then snapped outward.
        #expect(ChartDomain.line([40, 120]) == 30...130)
    }

    @Test func neverGoesBelowZero() {
        #expect(ChartDomain.line([1, 2]) == 0...5)
    }

    @Test func emptyValuesGiveTheFallbackRange() {
        #expect(ChartDomain.line([]) == 0...100)
    }

    @Test func sparklineIsMinToMaxWithPadding() {
        #expect(ChartDomain.sparkline([50, 52]) == 49...53)
    }

    @Test func flatSparklineStillHasARange() {
        let range = ChartDomain.sparkline([51, 51])
        #expect(range.lowerBound < 51 && range.upperBound > 51)
    }
}
