import Foundation

/// Y-axis ranges for the charts (IOS_UI_SPEC, Charts). Lines get a range around their data, so the trace is not a
/// flat stripe over a block that starts at zero. Bars keep zero; they are not defined here.
enum ChartDomain {
    /// A range for a line through `values`: snapped outward to `step`, padded by the larger of `minimumPadding`
    /// and 10 % of the spread. Never below zero, since heart rate and HRV are not negative.
    static func line(
        _ values: [Double],
        step: Double = 5,
        minimumPadding: Double = 3,
        empty: ClosedRange<Double> = 0...100
    ) -> ClosedRange<Double> {
        guard let low = values.min(), let high = values.max() else { return empty }
        let padding = max(minimumPadding, (high - low) * 0.1)
        let lower = max(0, floor((low - padding) / step) * step)
        let upper = ceil((high + padding) / step) * step
        return lower...max(upper, lower + step)
    }

    /// A range for a sparkline: min to max with 10 % padding. Sparklines have no axes, so it is not snapped.
    static func sparkline(_ values: [Double]) -> ClosedRange<Double> {
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        let padding = max(1, (high - low) * 0.1)
        return (low - padding)...(high + padding)
    }
}
