import Metrics
import SwiftUI

/// The span for the daily trend charts on the metric detail screens. The old Trends tab owned this control;
/// it now sits beside the values it describes.
enum TrendSpan: Int, CaseIterable, Identifiable {
    case week = 7
    case month = 30
    case quarter = 90

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .week: "7 d"
        case .month: "30 d"
        case .quarter: "90 d"
        }
    }

    /// Load twice the span so the first half can supply the previous-period delta chip.
    var loadedDayCount: Int { rawValue * 2 }
}

/// A 7, 30 or 90 day segmented control shared by the metric detail screens.
struct TrendSpanPicker: View {
    @Binding var span: TrendSpan

    var body: some View {
        Picker("Span", selection: $span) {
            ForEach(TrendSpan.allCases) { option in
                Text(option.label).tag(option)
            }
        }
        .pickerStyle(.segmented)
    }
}

/// A trend average with its change against the previous period, in the style of the old Trends cards.
struct TrendSummary: View {
    let series: TrendSeries
    let unit: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s8) {
            Text(series.average.map { Format.number($0, unit: unit) } ?? "--")
                .font(.metricValue)
                .monospacedDigit()
            if let change = series.change {
                DeltaChip(change: change, unit: unit)
            }
            Spacer(minLength: Spacing.s8)
        }
    }
}

extension TrendSeries {
    /// The latest day's value, worded for a trend card footer.
    func latestFooter(unit: String) -> String {
        guard let latest else { return "No data" }
        return "Latest \(Format.number(latest, unit: unit))"
    }
}
