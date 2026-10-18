/// Display-unit conversions between the metric values we store (cm, kg, °C) and the imperial /
/// Fahrenheit units the user may prefer (units setting). Storage, the wire format and the metric
/// formulas stay metric; these helpers are for form input and display only.
public enum UnitConversions {
    public static let cmPerInch = 2.54
    /// Exact enough for one-decimal display rounding; storage keeps kg.
    public static let poundsPerKilogram = 2.2046226218487757

    // MARK: Height

    /// cm as whole feet + inches, rounded to the nearest inch (180.3 cm → 5'11").
    public static func feetInches(fromCm cm: Double) -> (feet: Int, inches: Int) {
        let totalInches = Int((cm / cmPerInch).rounded())
        return (totalInches / 12, totalInches % 12)
    }

    /// Whole feet + inches as cm (5'11" → 180.34).
    public static func cm(fromFeetInches feet: Int, inches: Int) -> Double {
        Double(feet * 12 + inches) * cmPerInch
    }

    /// Display text like `5'11"`.
    public static func feetInchesText(_ feet: Int, _ inches: Int) -> String {
        "\(feet)'\(inches)\""
    }

    /// A closed range of cm as whole inches, widened outward: the lower bound rounds up and the
    /// upper bound rounds down, so every value accepted in display units converts back into the
    /// metric range (100...250 cm → 40...98 in, i.e. 3'4" ... 8'2").
    public static func inchesRange(fromCmRange range: ClosedRange<Double>) -> ClosedRange<Int> {
        Int((range.lowerBound / cmPerInch).rounded(.up)) ... Int((range.upperBound / cmPerInch).rounded(.down))
    }

    // MARK: Weight

    /// kg as lb rounded to display precision (one decimal).
    public static func poundsDisplay(fromKg kg: Double) -> Double {
        (kg * poundsPerKilogram * 10).rounded() / 10
    }

    /// lb as kg rounded to display precision (one decimal), so kg ↔ lb round-trips.
    public static func kilograms(fromPoundsDisplay pounds: Double) -> Double {
        (pounds / poundsPerKilogram * 10).rounded() / 10
    }

    /// A closed range of kg as lb, widened outward the same way as `inchesRange`
    /// (30...300 kg → 66.2...661.3 lb).
    public static func poundsRange(fromKgRange range: ClosedRange<Double>) -> ClosedRange<Double> {
        let lower = (range.lowerBound * poundsPerKilogram * 10).rounded(.up) / 10
        let upper = (range.upperBound * poundsPerKilogram * 10).rounded(.down) / 10
        return lower ... upper
    }

    // MARK: Temperature

    public static func fahrenheit(fromCelsius celsius: Double) -> Double {
        celsius * 9 / 5 + 32
    }

    public static func celsius(fromFahrenheit fahrenheit: Double) -> Double {
        (fahrenheit - 32) * 5 / 9
    }
}
