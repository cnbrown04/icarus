import SwiftUI

/// Number styles: rounded, semibold, scaled by Dynamic Type. Pair with `.monospacedDigit()` where values change.
extension Font {
    /// The live heart-rate value on Today.
    static var heroValue: Font {
        .system(.largeTitle, design: .rounded, weight: .semibold)
    }

    /// Metric values on tiles, cards and stat rows.
    static var metricValue: Font {
        .system(.title2, design: .rounded, weight: .semibold)
    }

    /// Units and secondary numbers beside a metric value.
    static var metricUnit: Font {
        .system(.subheadline, design: .rounded, weight: .medium)
    }
}
