import Testing
@testable import Metrics

@Suite("UnitConversions: cm/ft-in, kg/lb, °C/°F (units setting)")
struct UnitConversionsTests {
    @Test func heightRoundTripsThroughFeetInches() {
        // 180.3 cm is 70.98 in, i.e. 5'11" rounded to the nearest inch.
        #expect(UnitConversions.feetInches(fromCm: 180.3) == (5, 11))
        #expect(UnitConversions.cm(fromFeetInches: 5, inches: 11) == 180.34)
        // Round-trip stability: the back-conversion redisplays as the same ft+in.
        #expect(UnitConversions.feetInches(fromCm: UnitConversions.cm(fromFeetInches: 5, inches: 11)) == (5, 11))
        #expect(UnitConversions.feetInches(fromCm: UnitConversions.cm(fromFeetInches: 6, inches: 2)) == (6, 2))
        // Exact foot boundary.
        #expect(UnitConversions.feetInches(fromCm: 182.88) == (6, 0))
        #expect(UnitConversions.feetInchesText(5, 11) == "5'11\"")
    }

    @Test func weightRoundTripsThroughPoundsAtOneDecimal() {
        // 165 lb → 74.84 kg → 74.8 at display precision.
        #expect(UnitConversions.kilograms(fromPoundsDisplay: 165) == 74.8)
        // 74.8 kg → 164.91 lb → 164.9, i.e. about 165 lb.
        #expect(UnitConversions.poundsDisplay(fromKg: 74.8) == 164.9)
        // One-decimal round trips are stable: lb → kg → lb does not drift.
        #expect(UnitConversions.poundsDisplay(fromKg: UnitConversions.kilograms(fromPoundsDisplay: 165)) == 164.9)
        #expect(UnitConversions.kilograms(fromPoundsDisplay: UnitConversions.poundsDisplay(fromKg: 74.8)) == 74.8)
    }

    @Test func temperatureConvertsBothWays() {
        #expect(abs(UnitConversions.fahrenheit(fromCelsius: 37.0) - 98.6) < 0.01)
        #expect(abs(UnitConversions.celsius(fromFahrenheit: 98.6) - 37.0) < 0.01)
        // Exact anchor points convert exactly.
        #expect(UnitConversions.fahrenheit(fromCelsius: 0) == 32)
        #expect(UnitConversions.fahrenheit(fromCelsius: 100) == 212)
        #expect(UnitConversions.celsius(fromFahrenheit: 32) == 0)
        #expect(UnitConversions.celsius(fromFahrenheit: 212) == 100)
        // Round trip.
        #expect(abs(UnitConversions.celsius(fromFahrenheit: UnitConversions.fahrenheit(fromCelsius: 36.6)) - 36.6) < 0.0001)
    }

    @Test func rangesWidenOutwardSoDisplayValuesMapBackIntoMetric() {
        // 100...250 cm → 40...98 whole inches (3'4" ... 8'2"). 39 in is 99.06 cm, below the range.
        let inches = UnitConversions.inchesRange(fromCmRange: 100.0 ... 250.0)
        #expect(inches == 40 ... 98)
        #expect(UnitConversions.cm(fromFeetInches: 3, inches: 4) >= 100)
        #expect(UnitConversions.cm(fromFeetInches: 8, inches: 2) <= 250)

        // 30...300 kg → 66.2...661.3 lb. 66.1 lb is 29.94 kg, below the range.
        let pounds = UnitConversions.poundsRange(fromKgRange: 30.0 ... 300.0)
        #expect(pounds.lowerBound == 66.2)
        #expect(pounds.upperBound == 661.3)
        #expect(UnitConversions.kilograms(fromPoundsDisplay: pounds.lowerBound) >= 30)
        #expect(UnitConversions.kilograms(fromPoundsDisplay: pounds.upperBound) <= 300)
    }
}
