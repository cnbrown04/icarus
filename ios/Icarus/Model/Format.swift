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

    /// Band word for a stress value (PLAN.md 8.3).
    static func stressBand(_ value: Int) -> String {
        switch StressBand.of(stress: value) {
        case .low: "Low"
        case .moderate: "Moderate"
        case .high: "High"
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

    static func zoneLabel(_ zone: HeartRateZone) -> String {
        switch zone {
        case .below: "Below 50 %"
        case .zone1: "50-60 %"
        case .zone2: "60-70 %"
        case .zone3: "70-80 %"
        case .zone4: "80-90 %"
        case .zone5: "90 % and above"
        }
    }
}
