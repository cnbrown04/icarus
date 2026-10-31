import Foundation
import Testing
@testable import Metrics

@Suite("HealthMonitor (personal vital ranges)")
struct HealthMonitorTests {

    @Test func baselineNeedsMinimumNights() {
        let values = Array(repeating: 55.0, count: HealthMonitor.minimumNights - 1)
        #expect(HealthMonitor.baseline(for: .restingHR, nightly: values) == nil)
        #expect(HealthMonitor.baseline(for: .restingHR, nightly: values + [55]) != nil)
    }

    @Test func centreIsMedianAndBandUsesScaledMAD() throws {
        // Median 50. Absolute deviations sorted: 0,0,0,1,1,1,2,2,3, so MAD = 1 and 1.4826 · MAD ≈ 1.48.
        let values: [Double] = [48, 49, 50, 50, 50, 51, 51, 52, 53]
        let range = try #require(HealthMonitor.baseline(for: .hrv, nightly: values))
        #expect(range.center == 50)
        #expect(range.nights == 9)
        // The scaled MAD is below the 5 ms minimum half-width, so the band is 45...55.
        #expect(range.low == 45)
        #expect(range.high == 55)
    }

    @Test func steadyHistoryKeepsMinimumHalfWidth() throws {
        let range = try #require(HealthMonitor.baseline(for: .respiratoryRate, nightly: Array(repeating: 15.0, count: 10)))
        #expect(range.low == 14)
        #expect(range.high == 16)
    }

    @Test func skinTempCentreIsMeanNotMedian() throws {
        // Eight zeros and one 10: the mean is 10/9, while the median is 0.
        var values = Array(repeating: 0.0, count: 8)
        values.append(10)
        let range = try #require(HealthMonitor.baseline(for: .skinTemp, nightly: values))
        #expect(abs(range.center - 10.0 / 9.0) < 1e-9)
    }

    @Test func evaluateClassifiesTonightAgainstRange() throws {
        let rhr = try #require(HealthMonitor.baseline(for: .restingHR, nightly: Array(repeating: 55.0, count: 10)))
        let hrv = try #require(HealthMonitor.baseline(for: .hrv, nightly: Array(repeating: 60.0, count: 10)))
        let statuses = HealthMonitor.evaluate(
            tonight: [.restingHR: 60, .hrv: 61],
            baseline: [.restingHR: rhr, .hrv: hrv]
        )
        let byVital = Dictionary(uniqueKeysWithValues: statuses.map { ($0.vital, $0) })
        #expect(byVital[.restingHR]?.state == .above)
        #expect(byVital[.restingHR]?.deviation == 5)
        #expect(byVital[.hrv]?.state == .inRange)
        #expect(byVital[.respiratoryRate]?.state == .calibrating)
        #expect(byVital[.skinTemp]?.state == .calibrating)
        #expect(statuses.map(\.vital) == HealthMonitor.Vital.allCases)
    }

    @Test func belowRangeAndCalibratingVital() throws {
        let hrv = try #require(HealthMonitor.baseline(for: .hrv, nightly: Array(repeating: 60.0, count: 10)))
        let statuses = HealthMonitor.evaluate(tonight: [.hrv: 40], baseline: [.hrv: hrv])
        let hrvStatus = try #require(statuses.first { $0.vital == .hrv })
        #expect(hrvStatus.state == .below)
        let rhrStatus = try #require(statuses.first { $0.vital == .restingHR })
        #expect(rhrStatus.state == .calibrating)
    }

    @Test func noTonightWithRangeIsNotEvaluated() throws {
        let rhr = try #require(HealthMonitor.baseline(for: .restingHR, nightly: Array(repeating: 55.0, count: 10)))
        let statuses = HealthMonitor.evaluate(tonight: [:], baseline: [.restingHR: rhr])
        let status = try #require(statuses.first { $0.vital == .restingHR })
        #expect(status.state == .noTonight)
        #expect(status.deviation == nil)
    }

    @Test func summaryCountsOnlyEvaluatedVitals() throws {
        let rhr = try #require(HealthMonitor.baseline(for: .restingHR, nightly: Array(repeating: 55.0, count: 10)))
        let hrv = try #require(HealthMonitor.baseline(for: .hrv, nightly: Array(repeating: 60.0, count: 10)))
        let resp = try #require(HealthMonitor.baseline(for: .respiratoryRate, nightly: Array(repeating: 15.0, count: 10)))
        let statuses = HealthMonitor.evaluate(
            tonight: [.restingHR: 55, .hrv: 30, .respiratoryRate: 15, .skinTemp: 0.1],
            baseline: [.restingHR: rhr, .hrv: hrv, .respiratoryRate: resp]
        )
        // Skin temp has no range, so three vitals are evaluated and two of them are in range.
        let summary = HealthMonitor.summary(statuses)
        #expect(summary.evaluated == 3)
        #expect(summary.inRange == 2)
    }
}
