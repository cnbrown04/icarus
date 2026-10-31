import Charts
import Metrics
import SwiftUI

/// Sleep-stage colours: deep indigo, medium blue for core (light) sleep, cyan for REM and orange for awake. They
/// appear only inside the Sleep tab's charts and the Home compact bar, where they are the chart's series.
extension Palette {
    static let sleepDeep = Color.indigo
    static let sleepLight = Color.blue
    static let sleepREM = Color.cyan
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

/// Totals math shared by the Sleep tab and Home's compact bar.
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

    /// The chart's VoiceOver sentence: total sleep, deep, REM and awake.
    static func accessibleSummary(_ totals: [SleepStage: Int]) -> String {
        var parts = ["\(Format.duration(seconds: asleep(totals))) sleep"]
        for stage in SleepStage.stackOrder where stage != .light {
            parts.append("\(Format.duration(seconds: totals[stage] ?? 0)) \(stage.spokenName)")
        }
        return parts.joined(separator: ", ")
    }
}

/// An Apple-Health-style hypnogram: one lane per stage from Wake at the top to Deep at the bottom, with a coloured
/// band for each contiguous `StageSegment` across the night. At most four vertical gridlines.
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

    /// Whole hours between gridlines, so the night draws at most three or four.
    private var hourStride: Int {
        guard let first = segments.first, let last = segments.last else { return 1 }
        let hours = Double(max(last.endUnix, first.startUnix + 60) - first.startUnix) / 3_600
        return max(1, Int((hours / 3).rounded(.up)))
    }

    private var accessibilityValueText: String {
        segments.isEmpty ? "Stages pending" : SleepStageTotals.accessibleSummary(totals)
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
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: hourStride)) {
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

/// One stacked bar per night for the W, M and 6M ranges: hours of each stage, deepest at the bottom. An unstaged
/// night is one grey bar of its time asleep. Dragging across the chart selects the nearest night.
struct SleepNightBars: View {
    let days: [SleepModel.Day]
    @Binding var selectedID: Int64?

    var body: some View {
        Chart {
            ForEach(days) { day in
                if day.isStaged {
                    ForEach(SleepStage.stackOrder, id: \.self) { stage in
                        BarMark(
                            x: .value("Night", Date(epochMs: day.startMs), unit: .day),
                            y: .value("Hours", Self.hours(day.totals[stage] ?? 0))
                        )
                        .foregroundStyle(Palette.sleepStage(stage))
                    }
                } else {
                    BarMark(
                        x: .value("Night", Date(epochMs: day.startMs), unit: .day),
                        y: .value("Hours", Self.hours(Int(day.asleepS)))
                    )
                    .foregroundStyle(Color.secondary.opacity(0.35))
                }
            }
        }
        .metricChartStyle()
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard let plot = proxy.plotFrame else { return }
                                let x = value.location.x - geometry[plot].origin.x
                                guard let date: Date = proxy.value(atX: x) else { return }
                                selectedID = nearest(to: date)?.id
                            }
                    )
            }
        }
        .accessibilityLabel("Sleep by night")
    }

    private func nearest(to date: Date) -> SleepModel.Day? {
        let target = date.timeIntervalSince1970 * 1_000
        return days.min { abs(Double($0.startMs) - target) < abs(Double($1.startMs) - target) }
    }

    private static func hours(_ seconds: Int) -> Double {
        Double(seconds) / 3_600
    }
}

/// A compact single-row stacked stage bar with an optional one-line legend, for a list row or Home's last-night card.
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
