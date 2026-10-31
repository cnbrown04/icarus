import Foundation
import Metrics

/// Display strings. Numbers come first and units follow after a regular space (PLAN.md 15.1 rule 5-6).
enum Format {
    static func bpm(_ value: Double) -> String {
        "\(Int(value.rounded())) bpm"
    }

    static func bpm(_ value: Int) -> String {
        "\(value) bpm"
    }

    static func kcal(_ value: Double) -> String {
        "\(Int(value.rounded())) kcal"
    }

    static func ms(_ value: Double) -> String {
        "\(Int(value.rounded())) ms"
    }

    static func minutes(_ value: Int) -> String {
        "\(value) min"
    }

    /// A duration as hours and minutes, e.g. "7 h 12 min"; under an hour, minutes only (PLAN.md 15.1).
    static func duration(_ seconds: Int64) -> String {
        let minutes = Int((Double(seconds) / 60).rounded())
        guard minutes > 0 else { return "0 min" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    /// A minute count as hours and minutes, for chart summaries and calibration shortfalls.
    static func duration(minutes: Int) -> String {
        duration(Int64(minutes) * 60)
    }

    /// A stage total in whole seconds, the unit `sleepStageTotals` returns.
    static func duration(seconds: Int) -> String {
        duration(Int64(seconds))
    }

    /// A wall-clock time in the profile's zone, e.g. "10:48 PM". Used for sleep bounds.
    static func clock(_ epochMs: Int64, in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: Date(epochMs: epochMs))
    }

    /// A number with an optional unit, rounded. Used by trend averages.
    static func number(_ value: Double, unit: String) -> String {
        let text = "\(Int(value.rounded()))"
        return unit.isEmpty ? text : "\(text) \(unit)"
    }

    /// Seconds with one decimal and a regular space before the unit, for rhythm lengths (PLAN.md 15.1).
    static func seconds(_ value: Double) -> String {
        let tenths = (value * 10).rounded() / 10
        let text = tenths.formatted(.number.precision(.fractionLength(0...1)))
        return "\(text) s"
    }

    /// Percent with no space before the sign ("47%"), as Apple Health writes it.
    static func percent(_ value: Int) -> String {
        "\(value)%"
    }

    /// A fraction (0...1) as a percent ("47%").
    static func percent(_ fraction: Double) -> String {
        percent(Int((fraction * 100).rounded()))
    }

    /// Band word for a stress value (PLAN.md 8.3).
    static func stressBand(_ value: Int) -> String {
        bandName(StressBand.of(stress: value))
    }

    static func bandName(_ band: StressBand) -> String {
        switch band {
        case .low: "Low"
        case .moderate: "Moderate"
        case .high: "High"
        }
    }

    /// Nearest SF Symbol battery level for a percent.
    static func batterySymbol(_ percent: Int) -> String {
        switch percent {
        case ...12: "battery.0percent"
        case ...37: "battery.25percent"
        case ...62: "battery.50percent"
        case ...87: "battery.75percent"
        default: "battery.100percent"
        }
    }

    /// Text for a stress state with no value to show.
    static func stressState(_ state: StressState) -> String {
        switch state {
        case .value: "Value"
        case .calibrating: "Calibrating"
        case .exertion: "Exertion"
        case .insufficient: "Insufficient data"
        case .hrOnly: "HR only"
        }
    }

    /// Band word for a derived sleep quality (PLAN.md 8.1's sleep detection proxy).
    static func sleepQuality(_ quality: SleepQuality) -> String {
        switch quality {
        case .good: "Good"
        case .fair: "Fair"
        case .poor: "Poor"
        }
    }

    static func zoneLabel(_ zone: HeartRateZone) -> String {
        switch zone {
        case .below: "Below 50%"
        case .zone1: "50–60%"
        case .zone2: "60–70%"
        case .zone3: "70–80%"
        case .zone4: "80–90%"
        case .zone5: "90%+"
        }
    }
}
