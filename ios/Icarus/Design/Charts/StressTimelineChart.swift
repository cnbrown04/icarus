import Charts
import Metrics
import Store
import SwiftUI

/// Per-minute stress as an area whose fill follows the band thresholds (green, yellow, red), with
/// dashed guides at 33 and 66. Minutes without a value split the line, so calibrating and exertion
/// periods read as gaps. Tapping reads a minute on detail screens.
struct StressTimelineChart: View {
    let points: [StressTimelinePoint]
    /// Window start, normally local 00:00 for Today or 24 h ago on the detail screen.
    let fromMs: Int64
    /// Window end, normally now.
    let toMs: Int64

    @State private var selection: Date?

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

    private var bandFill: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: Palette.stressLow.opacity(0.38), location: 0),
                .init(color: Palette.stressLow.opacity(0.38), location: 0.33),
                .init(color: Palette.stressModerate.opacity(0.38), location: 0.33),
                .init(color: Palette.stressModerate.opacity(0.38), location: 0.66),
                .init(color: Palette.stressHigh.opacity(0.38), location: 0.66),
                .init(color: Palette.stressHigh.opacity(0.38), location: 1),
            ],
            startPoint: .bottom,
            endPoint: .top
        )
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
            ForEach(segments) { segment in
                ForEach(segment.points) { point in
                    AreaMark(
                        x: .value("Time", Date(epochMs: point.minuteMs)),
                        yStart: .value("Baseline", 0.0),
                        yEnd: .value("Stress", Double(point.stress ?? 0)),
                        series: .value("Segment", Int(segment.id))
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(bandFill)
                }
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
                .foregroundStyle(Palette.stressModerate.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [Spacing.s4, Spacing.s4]))
            RuleMark(y: .value("High starts", 66.0))
                .foregroundStyle(Palette.stressHigh.opacity(0.7))
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
        .chartYAxis {
            AxisMarks(position: .leading, values: [0.0, 33.0, 66.0, 100.0]) { _ in
                AxisValueLabel()
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) {
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .chartLegend(.hidden)
        .chartXSelection(value: $selection)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Stress timeline")
        .accessibilityValue(summary)
    }
}

/// Minutes in each band across a full-width card, with the band words.
struct StressBandMinutesRow: View {
    let summary: StressDaySummary

    var body: some View {
        HStack(spacing: Spacing.s16) {
            ForEach(summary.bandMinutes) { entry in
                HStack(spacing: Spacing.s4) {
                    Circle()
                        .fill(Palette.stress(entry.band))
                        .frame(width: Spacing.s8, height: Spacing.s8)
                    Text(Format.bandName(entry.band))
                        .font(.caption)
                    Text(Format.minutes(entry.minutes))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Minutes in each stress band")
        .accessibilityValue(accessibilityValueText)
    }

    private var accessibilityValueText: String {
        summary.bandMinutes
            .map { "\(Format.bandName($0.band)): \(Format.minutes($0.minutes))" }
            .joined(separator: ", ")
    }
}

/// The same minutes condensed into one line for a metric tile.
struct StressBandMinutesCompact: View {
    let summary: StressDaySummary

    var body: some View {
        HStack(spacing: Spacing.s8) {
            ForEach(summary.bandMinutes) { entry in
                HStack(spacing: Spacing.s4) {
                    Circle()
                        .fill(Palette.stress(entry.band))
                        .frame(width: Spacing.s4, height: Spacing.s4)
                    Text(shortName(entry.band))
                        .foregroundStyle(.secondary)
                    Text("\(entry.minutes)")
                        .monospacedDigit()
                }
            }
            Text("min")
                .foregroundStyle(.secondary)
        }
        .font(.caption2)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Minutes in each stress band")
        .accessibilityValue(accessibilityValueText)
    }

    private var accessibilityValueText: String {
        summary.bandMinutes
            .map { "\(Format.bandName($0.band)): \(Format.minutes($0.minutes))" }
            .joined(separator: ", ")
    }

    private func shortName(_ band: StressBand) -> String {
        switch band {
        case .low: "L"
        case .moderate: "M"
        case .high: "H"
        }
    }
}
