import Testing
@testable import Metrics

@Suite("MetricKind")
struct MetricKindTests {
    @Test func coversTheNineShownMetrics() {
        #expect(MetricKind.allCases.map(\.rawValue) == [
            "heartRate", "restingHR", "hrv", "stress", "respiratoryRate", "recovery", "strain", "calories", "sleep",
        ])
    }

    @Test func titlesAreTheUserFacingNames() {
        #expect(MetricKind.allCases.map(\.title) == [
            "Heart rate", "Resting heart rate", "Heart rate variability", "Stress", "Respiratory rate",
            "Recovery", "Strain", "Calories", "Sleep",
        ])
    }

    @Test func unitsMatchTheDisplayRules() {
        #expect(MetricKind.heartRate.unit == "bpm")
        #expect(MetricKind.restingHR.unit == "bpm")
        #expect(MetricKind.hrv.unit == "ms")
        #expect(MetricKind.respiratoryRate.unit == "br/min")
        #expect(MetricKind.recovery.unit == "%")
        #expect(MetricKind.calories.unit == "kcal")
        // Unitless or formatted as a duration, so no suffix.
        #expect(MetricKind.stress.unit == nil)
        #expect(MetricKind.strain.unit == nil)
        #expect(MetricKind.sleep.unit == nil)
    }

    @Test func onlyCaloriesSum() {
        for kind in MetricKind.allCases {
            let expected: MetricKind.Aggregation = kind == .calories ? .sum : .average
            #expect(kind.aggregation == expected, "\(kind)")
        }
    }

    @Test func intradayKindsAreHeartRateStressAndCalories() {
        let intraday = MetricKind.allCases.filter(\.hasIntraday)
        #expect(Set(intraday) == [.heartRate, .stress, .calories])
    }

    @Test func fractionDigitsKeepStrainAndRespiratoryRateToOneDecimal() {
        #expect(MetricKind.strain.fractionDigits == 1)
        #expect(MetricKind.respiratoryRate.fractionDigits == 1)
        #expect(MetricKind.recovery.fractionDigits == 0)
        #expect(MetricKind.hrv.fractionDigits == 0)
    }
}
