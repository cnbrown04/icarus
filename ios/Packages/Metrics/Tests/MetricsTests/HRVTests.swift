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
}
