import Charts
import Metrics
import Store
import SwiftUI

/// Per-minute stress as a line whose colour steps with the band (steps of the mind colour), with dashed guides at
/// 33 and 66. Minutes without a value split the line, so calibrating and exertion periods read as gaps. Dragging
/// reads a minute.
struct StressTimelineChart: View {
    let points: [StressTimelinePoint]
    /// Window start, normally local 00:00 for Today or 24 h ago on the detail screen.
    let fromMs: Int64
    /// Window end, normally now.
    let toMs: Int64
    /// Stimulant-active windows to shade behind the timeline. Clipped to `fromMs...toMs`.
    var medicationWindows: [MedicationWindow] = []

    @State private var selection: Date?

    private var shaded: [MedicationWindow] {
        medicationWindows.clipped(toMs: min(fromMs, toMs), max(fromMs, toMs))
    }

    /// A contiguous run of scored minutes. Gaps split segments so the line does not bridge them.
    private struct Segment: Identifiable {
        let id: Int64
        var points: [StressTimelinePoint]

        var average: Double {
            let values = points.compactMap(\.stress)
            guard !values.isEmpty else { return 0 }
            return Double(values.reduce(0, +)) / Double(values.count)
        }

        var band: StressBand {
            StressBand.of(stress: Int(average.rounded()))
        }
    }

    private var segments: [Segment] {
        var result: [Segment] = []
        for point in points where point.stress != nil {
            if let last = result.indices.last,
               point.minuteMs == result[last].points[result[last].points.count - 1].minuteMs + LocalTime.msPerMinute {
                result[last].points.append(point)
            } else {
                result.append(Segment(id: point.minuteMs, points: [point]))
            }
        }
        return result
    }

    private var scoredPoints: [StressTimelinePoint] {
        points.filter { $0.stress != nil }
    }

    private var selected: StressTimelinePoint? {
        guard let selection else { return nil }
        return scoredPoints.min { lhs, rhs in
            abs(Date(epochMs: lhs.minuteMs).timeIntervalSince(selection))
                < abs(Date(epochMs: rhs.minuteMs).timeIntervalSince(selection))
        }
    }

    private var xDomain: ClosedRange<Date> {
        let start = min(fromMs, toMs)
        let end = max(toMs, start + LocalTime.msPerMinute)
        return Date(epochMs: start)...Date(epochMs: end)
    }

    private var summary: String {
        let values = scoredPoints.compactMap(\.stress)
        guard !values.isEmpty else { return "No scored minutes" }
        let average = Double(values.reduce(0, +)) / Double(values.count)
        let rounded = Int(average.rounded())
        return "Average \(rounded), \(Format.stressBand(rounded).lowercased()). Peak \(values.max() ?? 0). "
            + "\(values.count) minutes scored."
    }

    var body: some View {
        Chart {
            MedicationWindowsOverlay.marks(shaded, yRange: 0...100)
            ForEach(segments) { segment in
                ForEach(segment.points) { point in
                    LineMark(
                        x: .value("Time", Date(epochMs: point.minuteMs)),
                        y: .value("Stress", Double(point.stress ?? 0)),
                        series: .value("Segment", Int(segment.id))
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(Palette.stress(segment.band))
                }
            }

            RuleMark(y: .value("Moderate starts", 33.0))
                .foregroundStyle(MetricCategory.mind.color.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [Spacing.s4, Spacing.s4]))
            RuleMark(y: .value("High starts", 66.0))
                .foregroundStyle(MetricCategory.mind.color.opacity(0.9))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [Spacing.s4, Spacing.s4]))

            if let selected, let stress = selected.stress {
                RuleMark(x: .value("Selected", Date(epochMs: selected.minuteMs)))
                    .foregroundStyle(.secondary)
                PointMark(
                    x: .value("Selected", Date(epochMs: selected.minuteMs)),
                    y: .value("Stress", Double(stress))
                )
                .foregroundStyle(Palette.stress(StressBand.of(stress: stress)))
                .annotation(position: .top) {
                    VStack(spacing: Spacing.s4) {
                        Text("\(stress)")
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                        Text(Date(epochMs: selected.minuteMs), style: .time)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(Spacing.s8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Spacing.s8, style: .continuous))
                }
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: 0.0...100.0)
        .metricChartStyle()
        .chartXSelection(value: $selection)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Stress timeline")
        .accessibilityValue(summary)
    }
}
