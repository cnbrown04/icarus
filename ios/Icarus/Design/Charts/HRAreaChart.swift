import Charts
import Metrics
import SwiftUI

/// Heart rate as a line in the heart category colour, with an optional average rule and a selection that reads one
/// point. Pass `.constant(nil)` where the chart is only a picture.
struct HRAreaChart: View {
    let points: [HRPoint]
    var average: Double?
    @Binding var selection: Date?
    /// Stimulant-active windows to shade behind the line (`MedicationWindowsOverlay`). Clipped to `xDomain`.
    var medicationWindows: [MedicationWindow] = []
    /// The visible time span. Set it whenever `medicationWindows` is set, so shading cannot widen the axis.
    var xDomain: ClosedRange<Date>?

    private var shaded: [MedicationWindow] {
        guard let xDomain else { return [] }
        return medicationWindows.clipped(
            toMs: Int64(xDomain.lowerBound.timeIntervalSince1970 * 1000),
            Int64(xDomain.upperBound.timeIntervalSince1970 * 1000)
        )
    }

    private var selected: HRPoint? {
        guard let selection else { return nil }
        return points.min { lhs, rhs in
            abs(lhs.date.timeIntervalSince(selection)) < abs(rhs.date.timeIntervalSince(selection))
        }
    }

    private var yRange: ClosedRange<Double> {
        ChartDomain.line(points.map(\.bpm))
    }

    var body: some View {
        let range = yRange
        Chart {
            MedicationWindowsOverlay.marks(shaded, yRange: range)
            ForEach(points) { point in
                LineMark(x: .value("Time", point.date), y: .value("Heart rate", point.bpm))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(Palette.heartRate)
            }
            if let average {
                RuleMark(y: .value("Average", average))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .leading) {
                        Text(Format.bpm(average))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
            }
            if let selected {
                RuleMark(x: .value("Selected", selected.date))
                    .foregroundStyle(.secondary)
                    .annotation(position: .top) {
                        VStack(spacing: Spacing.s4) {
                            Text(Format.bpm(selected.bpm))
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                            Text(selected.date, style: .time)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(Spacing.s8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                PointMark(x: .value("Selected", selected.date), y: .value("Heart rate", selected.bpm))
                    .foregroundStyle(Palette.heartRate)
            }
        }
        .chartYScale(domain: range)
        .metricChartStyle()
        .chartXSelection(value: $selection)
        .modifier(OptionalXDomain(domain: xDomain))
    }
}

/// Applies an explicit x domain only when one is given, so charts without one keep their automatic scale.
private struct OptionalXDomain: ViewModifier {
    let domain: ClosedRange<Date>?

    func body(content: Content) -> some View {
        if let domain {
            content.chartXScale(domain: domain)
        } else {
            content
        }
    }
}
