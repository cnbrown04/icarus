import Charts
import Metrics
import SwiftUI

/// Chart heights. Detail pages use `detail`, and compact previews use `compact`.
enum ChartHeight {
    static let detail: CGFloat = 220
    static let compact: CGFloat = 120
}

/// The one chart style for metric charts: the y axis on the trailing side with at most four marks, muted caption
/// labels, faint gridlines, muted x labels, and no legend. Apply it to a `Chart`, and draw the series in the metric's
/// category colour with no gradient fill.
struct MetricChartModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                    AxisValueLabel().font(.caption2).foregroundStyle(.secondary)
                }
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisValueLabel().font(.caption2).foregroundStyle(.secondary)
                }
            }
            .chartLegend(.hidden)
    }
}

extension View {
    /// Applies the metric chart style (`MetricChartModifier`).
    func metricChartStyle() -> some View {
        modifier(MetricChartModifier())
    }
}

/// One metric in a Summary or Browse list: its glyph and name in the category colour, an optional time caption, then
/// the value and unit. A missing value reads "—", and its unit is dropped.
struct MetricRow: View {
    let kind: MetricKind
    let value: String?
    let unit: String?
    /// When the value was measured, such as "Last night" or "10:42". Nil when there is no time to show.
    let caption: String?

    /// Two lines, as Apple Health lays out a metric: the category glyph and name with the time trailing on top,
    /// the figure below. Nothing shares a line with the figure, so long names never wrap into it.
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s8) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s8) {
                Label {
                    Text(kind.title)
                        .lineLimit(1)
                } icon: {
                    Image(systemName: kind.symbol)
                        .symbolRenderingMode(.hierarchical)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(kind.category.color)
                .layoutPriority(1)
                Spacer(minLength: Spacing.s8)
                if let caption {
                    Text(caption)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s4) {
                Text(value ?? "—")
                    .font(.figure)
                    .monospacedDigit()
                if let value, let unit {
                    Text(unit)
                        .font(.figureUnit)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        }
        .padding(.vertical, Spacing.s4)
        .accessibilityElement(children: .combine)
    }
}

/// The one empty-state pattern: a single secondary line, with an optional borderless action beneath it.
struct EmptyStateRow: View {
    let text: String
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s8) {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderless)
            }
        }
    }
}
