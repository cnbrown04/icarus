import Foundation

// MetricKind.swift: the metrics the app shows, one case each. The app's category colours and SF Symbols live in
// Design (`MetricCategory.swift`, `Symbols.swift`); the stored values come from Store (`MetricSeries.swift`).
// Nothing here reads data.

/// One metric the app shows on its own page (`MetricDetailView`) and in its lists.
public enum MetricKind: String, CaseIterable, Sendable {
    case heartRate
    case restingHR
    case hrv
    case stress
    case respiratoryRate
    case recovery
    case strain
    case calories
    case sleep

    /// How a range of days is reduced to one number: a mean for physiological values, a total for energy.
    public enum Aggregation: Sendable, Equatable {
        case average
        case sum
    }

    /// The name shown on rows and page titles.
    public var title: String {
        switch self {
        case .heartRate: "Heart Rate"
        case .restingHR: "Resting Heart Rate"
        case .hrv: "Heart Rate Variability"
        case .stress: "Stress"
        case .respiratoryRate: "Respiratory Rate"
        case .recovery: "Recovery"
        case .strain: "Strain"
        case .calories: "Calories"
        case .sleep: "Sleep"
        }
    }

    /// The unit printed after the value. Nil when the value is unitless (stress, strain) or a duration (sleep),
    /// which the UI formats as hours and minutes rather than with a suffix.
    public var unit: String? {
        switch self {
        case .heartRate, .restingHR: "bpm"
        case .hrv: "ms"
        case .respiratoryRate: "br/min"
        case .recovery: "%"
        case .calories: "kcal"
        case .stress, .strain, .sleep: nil
        }
    }

    /// Decimal places the value is shown with.
    public var fractionDigits: Int {
        switch self {
        case .respiratoryRate, .strain: 1
        case .heartRate, .restingHR, .hrv, .stress, .recovery, .calories, .sleep: 0
        }
    }

    /// Calories add up over a day or week. Everything else is averaged.
    public var aggregation: Aggregation {
        switch self {
        case .calories: .sum
        case .heartRate, .restingHR, .hrv, .stress, .respiratoryRate, .recovery, .strain, .sleep: .average
        }
    }

    /// True when the detail page can chart the metric through the day (minute or hourly values), not only per day.
    public var hasIntraday: Bool {
        switch self {
        case .heartRate, .stress, .calories: true
        case .restingHR, .hrv, .respiratoryRate, .recovery, .strain, .sleep: false
        }
    }
}
