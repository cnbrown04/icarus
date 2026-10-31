import SwiftUI

/// Type for the Apple Health look. Screens use the three figure styles below plus `.body`, `.subheadline` and
/// `.footnote`, and at most three sizes per screen. Figures are rounded and semibold, and scale with Dynamic Type.
/// Pair with `.monospacedDigit()` where values change.
extension Font {
    /// The big figure on a detail header.
    static var figureLarge: Font {
        .system(.largeTitle, design: .rounded, weight: .semibold)
    }

    /// A figure in a list row or a secondary header.
    static var figure: Font {
        .system(.title2, design: .rounded, weight: .semibold)
    }

    /// The unit beside a figure. Set it in secondary colour.
    static var figureUnit: Font {
        .system(.subheadline, design: .rounded, weight: .medium)
    }

    /// The live heart-rate value on Today.
    /// Deprecated: use `figureLarge`.
    static var heroValue: Font {
        .system(.largeTitle, design: .rounded, weight: .semibold)
    }

    /// Metric values on tiles, cards and stat rows.
    /// Deprecated: use `figure`.
    static var metricValue: Font {
        .system(.title2, design: .rounded, weight: .semibold)
    }

    /// Units and secondary numbers beside a metric value.
    /// Deprecated: use `figureUnit`.
    static var metricUnit: Font {
        .system(.subheadline, design: .rounded, weight: .medium)
    }
}
