import Charts
import Metrics
import SwiftUI

/// Sleep-stage colours: deep indigo, medium blue for light sleep, teal for REM and orange for wake.
/// Defined here beside the only screens that use them, alongside the chart they colour.
extension Palette {
    static let sleepDeep = Color.indigo
    static let sleepLight = Color.blue
    static let sleepREM = Color.teal
    static let sleepWake = Color.orange

    static func sleepStage(_ stage: SleepStage) -> Color {
        switch stage {
        case .wake: Palette.sleepWake
        case .light: Palette.sleepLight
        case .deep: Palette.sleepDeep
        case .rem: Palette.sleepREM
        }
    }
}

extension SleepStage {
    /// Summary and compact-bar order, deepest first. This is also the hypnogram's bottom-to-top lane
    /// order: Swift Charts' y axis rises, so Deep sits at lane 0 and Wake at lane 3.
    static let stackOrder: [SleepStage] = [.deep, .light, .rem, .wake]

    /// Lane and legend label. Apple calls light sleep "Core"; this app says "Light".
    var displayName: String {
        switch self {
        case .wake: "Wake"
        case .light: "Light"
        case .deep: "Deep"
        case .rem: "REM"
        }
    }

    /// The word used inside an accessibility sentence, e.g. "22 min awake".
    var spokenName: String {
        switch self {
        case .wake: "awake"
        case .light: "light"
        case .deep: "deep"
        case .rem: "REM"
        }
    }
}

/// Totals math shared by the chart summary, the stage row and Home's compact bar.
enum SleepStageTotals {
    static func total(_ totals: [SleepStage: Int]) -> Int {
        totals.values.reduce(0, +)
    }

    /// Asleep excludes wake, matching `SleepStaging.efficiency`.
    static func asleep(_ totals: [SleepStage: Int]) -> Int {
        (totals[.light] ?? 0) + (totals[.deep] ?? 0) + (totals[.rem] ?? 0)
    }

    static func percent(_ stage: SleepStage, of totals: [SleepStage: Int]) -> Int {
        let total = total(totals)
        guard total > 0 else { return 0 }
        return Int((Double(totals[stage] ?? 0) / Double(total) * 100).rounded())
    }

    /// One line of stage totals, deepest first, for a list row.
    static func summary(_ totals: [SleepStage: Int]) -> String {
        SleepStage.stackOrder
            .map { "\($0.displayName) \(Format.duration(seconds: totals[$0] ?? 0))" }
            .joined(separator: " · ")
    }

    /// The chart's VoiceOver sentence: total sleep, deep, REM and awake.
    static func accessibleSummary(_ totals: [SleepStage: Int]) -> String {
        var parts = ["\(Format.duration(seconds: asleep(totals))) sleep"]
        for stage in SleepStage.stackOrder where stage != .light {
            parts.append("\(Format.duration(seconds: totals[stage] ?? 0)) \(stage.spokenName)")
        }
        return parts.joined(separator: ", ")
    }
}

/// An Apple-Health-style hypnogram: one lane per stage from Wake at the top to Deep at the bottom,
/// with a coloured band for each contiguous `StageSegment` across the night.
struct SleepStageChart: View {
    let segments: [StageSegment]
    let totals: [SleepStage: Int]

    private static let laneHalfHeight = 0.38

    private var xDomain: ClosedRange<Date> {
        guard let first = segments.first, let last = segments.last else {
            let now = Date()
            return now...now.addingTimeInterval(3600)
        }
        let start = first.startUnix
        let end = max(last.endUnix, start + 60)
        return Date(epochMs: start * 1000)...Date(epochMs: end * 1000)
    }

    private var accessibilityValueText: String {
        segments.isEmpty ? "Stages not yet computed" : SleepStageTotals.accessibleSummary(totals)
    }

    var body: some View {
        Chart {
            ForEach(segments, id: \.startUnix) { segment in
                RectangleMark(
                    xStart: .value("Start", Date(epochMs: segment.startUnix * 1000)),
                    xEnd: .value("End", Date(epochMs: segment.endUnix * 1000)),
                    yStart: .value("Lane", Self.lane(segment.stage) - Self.laneHalfHeight),
                    yEnd: .value("Lane", Self.lane(segment.stage) + Self.laneHalfHeight)
                )
                .foregroundStyle(Palette.sleepStage(segment.stage))
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: -0.5...3.5)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0.0, 1.0, 2.0, 3.0]) { value in
                AxisValueLabel {
                    if let lane = value.as(Double.self), let stage = Self.stage(lane: Int(lane.rounded())) {
                        Text(stage.displayName)
                            .font(.caption2)
                            .foregroundStyle(Palette.sleepStage(stage))
                    }
                }
            }
        }
        .chartXAxis {
            // Hourly grid lines and wall-clock labels across bedtime to wake.
            AxisMarks(values: .stride(by: .hour, count: 1)) {
                AxisGridLine()
                    .foregroundStyle(Color.secondary.opacity(0.18))
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .chartLegend(.hidden)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hypnogram")
        .accessibilityValue(accessibilityValueText)
    }

    private static func lane(_ stage: SleepStage) -> Double {
        Double(SleepStage.stackOrder.firstIndex(of: stage) ?? 0)
    }

    private static func stage(lane: Int) -> SleepStage? {
        SleepStage.stackOrder.indices.contains(lane) ? SleepStage.stackOrder[lane] : nil
    }
}

/// The stage breakdown under the hypnogram: Deep / Light / REM / Wake durations and their share of
/// time in bed. Columns become stacked rows at accessibility text sizes.
struct SleepStageSummaryRow: View {
    let totals: [SleepStage: Int]

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Spacing.s8) {
                    ForEach(SleepStage.stackOrder, id: \.self) { stage in
                        HStack(spacing: Spacing.s8) {
                            swatch(stage)
                            Text(stage.displayName)
                                .font(.subheadline)
                            Spacer(minLength: Spacing.s8)
                            values(stage, alignment: .trailing)
                        }
                    }
                }
            } else {
                HStack(alignment: .top, spacing: Spacing.s8) {
                    ForEach(SleepStage.stackOrder, id: \.self) { stage in
                        VStack(alignment: .leading, spacing: Spacing.s4) {
                            HStack(spacing: Spacing.s4) {
                                swatch(stage)
                                Text(stage.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            values(stage, alignment: .leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sleep stages")
        .accessibilityValue(accessibilityValueText)
    }

    private func swatch(_ stage: SleepStage) -> some View {
        Circle()
            .fill(Palette.sleepStage(stage))
            .frame(width: Spacing.s8, height: Spacing.s8)
    }

    private func values(_ stage: SleepStage, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: Spacing.s4) {
            Text(Format.duration(seconds: totals[stage] ?? 0))
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
            Text(Format.percent(SleepStageTotals.percent(stage, of: totals)))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var accessibilityValueText: String {
        SleepStage.stackOrder
            .map { stage in
                "\(stage.displayName): \(Format.duration(seconds: totals[stage] ?? 0)), "
                    + Format.percent(SleepStageTotals.percent(stage, of: totals))
            }
            .joined(separator: ". ")
    }
}

/// A compact single-row stacked stage bar with a one-line legend, sized for Home's last-night card.
struct SleepStageBar: View {
    let totals: [SleepStage: Int]
    var showsLegend = true

    private var total: Int {
        SleepStageTotals.total(totals)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s4) {
            bar
            if showsLegend {
                legend
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sleep stages")
        .accessibilityValue(accessibilityValueText)
    }

    private var bar: some View {
        GeometryReader { proxy in
            if total > 0 {
                HStack(spacing: .zero) {
                    ForEach(SleepStage.stackOrder, id: \.self) { stage in
                        let seconds = totals[stage] ?? 0
                        if seconds > 0 {
                            Rectangle()
                                .fill(Palette.sleepStage(stage))
                                .frame(width: proxy.size.width * CGFloat(seconds) / CGFloat(total))
                        }
                    }
                }
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(0.2))
            }
        }
        .frame(height: Spacing.s8)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }

    private var legend: some View {
        HStack(spacing: Spacing.s8) {
            ForEach(SleepStage.stackOrder, id: \.self) { stage in
                HStack(spacing: Spacing.s4) {
                    Circle()
                        .fill(Palette.sleepStage(stage))
                        .frame(width: Spacing.s4, height: Spacing.s4)
                    Text("\(stage.displayName) \(Format.percent(SleepStageTotals.percent(stage, of: totals)))")
                        .monospacedDigit()
                }
            }
            Spacer(minLength: .zero)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .accessibilityHidden(true)
    }

    private var accessibilityValueText: String {
        SleepStage.stackOrder
            .map { "\($0.displayName) \(Format.percent(SleepStageTotals.percent($0, of: totals)))" }
            .joined(separator: ", ")
    }
}
