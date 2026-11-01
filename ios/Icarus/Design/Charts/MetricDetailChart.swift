import Charts
import Metrics
import Store
import SwiftUI

/// The one main chart on a metric's detail page. The day view draws minute or hour values (a line, or bars for
/// calories); the daily ranges draw one value per day (a line or bars) and heart rate draws each day's min–max
/// range with its average. Series take the metric's category colour. The period average is the only dashed line.
struct MetricDetailChart: View {
    let data: MetricDetailData
    @Binding var selection: Date?

    private var color: Color { data.kind.category.color }

    var body: some View {
        if data.range == .day {
            dayChart
        } else if data.showsReadings {
            readingsChart
        } else {
            dailyChart
        }
    }

    // MARK: Day

    @ViewBuilder private var dayChart: some View {
        let domain = Date(epochMs: data.dayStartMs)...Date(epochMs: data.dayEndMs)
        if data.kind == .calories {
            Chart {
                ForEach(data.points, id: \.tsMs) { point in
                    BarMark(x: .value("Hour", Date(epochMs: point.tsMs), unit: .hour), y: .value("kcal", point.value))
                        .foregroundStyle(color)
                }
                if let selected = selectedPoint {
                    RuleMark(x: .value("Selected", Date(epochMs: selected.tsMs)))
                        .foregroundStyle(Color.secondary)
                }
            }
            .chartXScale(domain: domain)
            .metricChartStyle()
            .chartXSelection(value: $selection)
            .accessibilityLabel("Calories, Today")
        } else if data.kind.isNightly {
            // Last night's window readings as one line across the night.
            Chart {
                readingLines
                if let selected = selectedPoint {
                    RuleMark(x: .value("Selected", Date(epochMs: selected.tsMs)))
                        .foregroundStyle(Color.secondary)
                    PointMark(x: .value("Selected", Date(epochMs: selected.tsMs)), y: .value(data.kind.title, selected.value))
                        .foregroundStyle(color)
                }
            }
            .chartXScale(domain: domain)
            .chartYScale(domain: ChartDomain.line((data.points + data.dayPoints).map(\.value)))
            .metricChartStyle()
            .chartXSelection(value: $selection)
            .accessibilityLabel("\(data.kind.title), readings last night")
        } else {
            let range = dayDomain
            Chart {
                MedicationWindowsOverlay.marks(data.medication, yRange: range)
                ForEach(data.points, id: \.tsMs) { point in
                    LineMark(x: .value("Time", Date(epochMs: point.tsMs)), y: .value(data.kind.title, point.value))
                        .interpolationMethod(.linear)
                        .foregroundStyle(lineStyle(data.points.map(\.value)))
                }
                if let value = data.value {
                    averageRule(value)
                }
                if let selected = selectedPoint {
                    RuleMark(x: .value("Selected", Date(epochMs: selected.tsMs)))
                        .foregroundStyle(Color.secondary)
                    PointMark(x: .value("Selected", Date(epochMs: selected.tsMs)), y: .value(data.kind.title, selected.value))
                        .foregroundStyle(pointColor(selected.value))
                }
            }
            .chartXScale(domain: domain)
            .chartYScale(domain: range)
            .metricChartStyle()
            .chartXSelection(value: $selection)
            .accessibilityLabel("\(data.kind.title), today")
        }
    }

    private var dayDomain: ClosedRange<Double> {
        switch data.kind {
        case .stress: 0...100
        default: ChartDomain.line((data.points + data.dayPoints).map(\.value))
        }
    }

    private var selectedPoint: MetricPoint? {
        guard let selection else { return nil }
        return data.nearestPoint(to: selection)
    }

    // MARK: Readings

    /// Every window reading of the span's nights at its own time, one line per night, with the period average.
    private var readingsChart: some View {
        Chart {
            readingLines
            if let value = data.value {
                averageRule(value)
            }
            if let selected = selectedPoint {
                RuleMark(x: .value("Selected", Date(epochMs: selected.tsMs)))
                    .foregroundStyle(Color.secondary)
                PointMark(x: .value("Selected", Date(epochMs: selected.tsMs)), y: .value(data.kind.title, selected.value))
                    .foregroundStyle(color)
            }
        }
        .chartXScale(domain: Date(epochMs: data.dayStartMs)...Date(epochMs: data.dayEndMs))
        .chartYScale(domain: ChartDomain.line((data.points + data.dayPoints).map(\.value)))
        .metricChartStyle()
        .chartXSelection(value: $selection)
        .accessibilityLabel("\(data.kind.title), every reading")
    }

    /// The readings as straight lines: sleep readings solid, one series per night (a gap over `nightBreakMs` is
    /// the day between two sleeps); awake readings lighter, broken wherever a window or more is missing, since the
    /// strap sends few beat intervals while you move. A run of one awake reading is a dot.
    @ChartContentBuilder private var readingLines: some ChartContent {
        ForEach(Self.runs(data.points, maxGapMs: Self.nightBreakMs), id: \.first?.tsMs) { night in
            ForEach(night, id: \.tsMs) { point in
                LineMark(x: .value("Time", Date(epochMs: point.tsMs)), y: .value(data.kind.title, point.value),
                         series: .value("Night", "night-\(night.first?.tsMs ?? 0)"))
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: data.range == .sixMonths ? 1 : 1.5))
                    .foregroundStyle(color)
            }
        }
        ForEach(Self.runs(data.dayPoints, maxGapMs: awakeBreakMs), id: \.first?.tsMs) { run in
            if run.count == 1, let point = run.first {
                PointMark(x: .value("Time", Date(epochMs: point.tsMs)), y: .value(data.kind.title, point.value))
                    .foregroundStyle(color.opacity(0.4))
                    .symbolSize(Spacing.s8)
            } else {
                ForEach(run, id: \.tsMs) { point in
                    LineMark(x: .value("Time", Date(epochMs: point.tsMs)), y: .value(data.kind.title, point.value),
                             series: .value("Awake", "awake-\(run.first?.tsMs ?? 0)"))
                        .interpolationMethod(.linear)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .foregroundStyle(color.opacity(0.4))
                }
            }
        }
    }

    /// Longer than any gap inside one night's readings (30-minute respiratory windows, a missing window or two), far
    /// shorter than the day between nights.
    static let nightBreakMs: Int64 = 3 * 3_600_000

    /// Awake readings join only across adjacent windows: 5 minutes apart for HRV, 30 for respiratory rate.
    private var awakeBreakMs: Int64 {
        data.kind == .respiratoryRate ? 30 * 60_000 : 5 * 60_000
    }

    /// `points` (oldest first) split wherever consecutive readings are more than `maxGapMs` apart.
    static func runs(_ points: [MetricPoint], maxGapMs: Int64) -> [[MetricPoint]] {
        var runs: [[MetricPoint]] = []
        for point in points {
            if let last = runs.last?.last, point.tsMs - last.tsMs <= maxGapMs {
                runs[runs.count - 1].append(point)
            } else {
                runs.append([point])
            }
        }
        return runs
    }

    // MARK: Daily

    @ViewBuilder private var dailyChart: some View {
        if data.kind == .heartRate {
            Chart {
                ForEach(data.rows) { row in
                    if let low = row.low, let high = row.high {
                        BarMark(
                            x: .value("Day", row.date, unit: .day),
                            yStart: .value("Lowest", low),
                            yEnd: .value("Highest", high),
                            width: .fixed(Spacing.s8)
                        )
                        .foregroundStyle(color.opacity(0.5))
                    }
                }
                ForEach(data.rows) { row in
                    if let value = row.value {
                        PointMark(x: .value("Day", row.date, unit: .day), y: .value("Average", value))
                            .foregroundStyle(color)
                            .symbolSize(Spacing.s16)
                    }
                }
                if let value = data.value {
                    averageRule(value)
                }
                if let selected = selectedRow {
                    RuleMark(x: .value("Selected", selected.date, unit: .day))
                        .foregroundStyle(Color.secondary)
                }
            }
            .chartYScale(domain: ChartDomain.line(data.rows.flatMap { [$0.low, $0.high].compactMap { $0 } }))
            .metricChartStyle()
            .chartXSelection(value: $selection)
            .accessibilityLabel("Heart Rate Range by Day")
        } else if data.kind.aggregation == .sum {
            Chart {
                ForEach(data.rows) { row in
                    if let value = row.value {
                        BarMark(x: .value("Day", row.date, unit: .day), y: .value(data.kind.title, value))
                            .foregroundStyle(color)
                    }
                }
                if let selected = selectedRow {
                    RuleMark(x: .value("Selected", selected.date, unit: .day))
                        .foregroundStyle(Color.secondary)
                }
            }
            .metricChartStyle()
            .chartXSelection(value: $selection)
            .accessibilityLabel("\(data.kind.title) by day")
        } else {
            Chart {
                // Straight segments between consecutive days only: a missing day breaks the line (each run is its
                // own series), so sparse history never draws a curve across weeks with no data.
                ForEach(Self.runs(data.rows), id: \.self) { run in
                    ForEach(run, id: \.self) { index in
                        let row = data.rows[index]
                        LineMark(x: .value("Day", row.date, unit: .day), y: .value(data.kind.title, row.value ?? 0),
                                 series: .value("Run", run.first ?? 0))
                            .interpolationMethod(.linear)
                            .foregroundStyle(lineStyle(run.compactMap { data.rows[$0].value }))
                    }
                }
                ForEach(data.rows) { row in
                    if let value = row.value {
                        PointMark(x: .value("Day", row.date, unit: .day), y: .value(data.kind.title, value))
                            .foregroundStyle(pointColor(value))
                            .symbolSize(Spacing.s16)
                    }
                }
                if let value = data.value {
                    averageRule(value)
                }
                if let selected = selectedRow {
                    RuleMark(x: .value("Selected", selected.date, unit: .day))
                        .foregroundStyle(Color.secondary)
                }
            }
            .chartYScale(domain: data.kind == .stress ? 0...100 : ChartDomain.line(data.rows.compactMap(\.value)))
            .metricChartStyle()
            .chartXSelection(value: $selection)
            .accessibilityLabel("\(data.kind.title) by day")
        }
    }

    /// Indices of `rows` grouped into runs of consecutive days that all have a value.
    static func runs(_ rows: [MetricDayRow]) -> [[Int]] {
        var runs: [[Int]] = []
        var current: [Int] = []
        for (index, row) in rows.enumerated() {
            if row.value != nil {
                current.append(index)
            } else if !current.isEmpty {
                runs.append(current)
                current = []
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    private var selectedRow: MetricDayRow? {
        guard let selection else { return nil }
        return data.nearestRow(to: selection)
    }

    // MARK: Shared

    /// Stress lines take the green-to-red scale, placed so each height has its own stress value's colour; every other
    /// line takes the category colour. `values` are the values of the one series the style is for.
    private func lineStyle(_ values: [Double]) -> AnyShapeStyle {
        data.kind == .stress ? AnyShapeStyle(Palette.stressGradient(values)) : AnyShapeStyle(color)
    }

    private func pointColor(_ value: Double) -> Color {
        data.kind == .stress ? Palette.stress(value) : color
    }

    /// The period average: the only dashed line, in neutral grey.
    private func averageRule(_ value: Double) -> some ChartContent {
        RuleMark(y: .value("Average", value))
            .foregroundStyle(Color.secondary)
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [Spacing.s4, Spacing.s4]))
    }
}
