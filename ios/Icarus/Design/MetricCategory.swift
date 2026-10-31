import Metrics
import SwiftUI

/// The six categories that group metrics, each with one colour. Colour carries meaning: a category colour appears
/// only on that category's glyphs and chart series, so the same colour means the same thing on every screen.
/// System colours, so light and dark mode come from the system.
enum MetricCategory: CaseIterable {
    case heart
    case activity
    case recovery
    case sleep
    case mind
    case respiratory

    var color: Color {
        switch self {
        case .heart: .pink
        case .activity: .orange
        case .recovery: .green
        case .sleep: .teal
        case .mind: .purple
        case .respiratory: .blue
        }
    }

    var title: String {
        switch self {
        case .heart: "Heart"
        case .activity: "Activity"
        case .recovery: "Recovery"
        case .sleep: "Sleep"
        case .mind: "Mind"
        case .respiratory: "Respiratory"
        }
    }
}

extension MetricKind {
    /// The category this metric is grouped under in Browse and coloured with on its glyph and chart.
    var category: MetricCategory {
        switch self {
        case .heartRate, .restingHR, .hrv: .heart
        case .stress: .mind
        case .respiratoryRate: .respiratory
        case .recovery: .recovery
        case .strain, .calories: .activity
        case .sleep: .sleep
        }
    }
}

extension Palette {
    /// The colour of a category. Same value as `MetricCategory.color`.
    static func category(_ category: MetricCategory) -> Color {
        category.color
    }

    /// Neutral shading behind a chart for a medication window. It marks a time, not a state, so it has no hue.
    static let medicationShade = Color.secondary.opacity(0.15)
}
