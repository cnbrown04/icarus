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
        } else {
            let range = dayDomain
            Chart {
                MedicationWindowsOverlay.marks(data.medication, yRange: range)
                ForEach(data.points, id: \.tsMs) { point in
                    LineMark(x: .value("Time", Date(epochMs: point.tsMs)), y: .value(data.kind.title, point.value))
                        .interpolationMethod(.linear)
                        .foregroundStyle(color)
                }
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
        default: ChartDomain.line(data.points.map(\.value))
        }
    }

    private var selectedPoint: MetricPoint? {
        guard let selection else { return nil }
        return data.nearestPoint(to: selection)
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
                            .foregroundStyle(color)
                    }
                }
                ForEach(data.rows) { row in
                    if let value = row.value {
                        PointMark(x: .value("Day", row.date, unit: .day), y: .value(data.kind.title, value))
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
            .chartYScale(domain: ChartDomain.line(data.rows.compactMap(\.value)))
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

    /// The period average: the only dashed line, in neutral grey.
    private func averageRule(_ value: Double) -> some ChartContent {
        RuleMark(y: .value("Average", value))
            .foregroundStyle(Color.secondary)
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [Spacing.s4, Spacing.s4]))
    }
}
