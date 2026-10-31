import Charts
import Metrics
import Store
import SwiftUI

/// The daily series Trends can chart. Each reads one field of `DailyScorePoint`.
enum TrendMetric: String, CaseIterable, Identifiable {
    case recovery
    case hrv
    case restingHR
    case respiratoryRate
    case sleepPerformance
    case strain
    case stress

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recovery: "Recovery"
        case .hrv: "HRV"
        case .restingHR: "Resting HR"
        case .respiratoryRate: "Resp. rate"
        case .sleepPerformance: "Sleep performance"
        case .strain: "Strain"
        case .stress: "Stress"
        }
    }

    /// Shown after every value. Strain and stress carry their scale, so the number reads without a legend.
    var unit: String {
        switch self {
        case .recovery, .sleepPerformance: "%"
        case .hrv: "ms"
        case .restingHR: "bpm"
        case .respiratoryRate: "br/min"
        case .strain: "/ 21"
        case .stress: "/ 100"
        }
    }

    var tint: Color {
        switch self {
        case .recovery: .green
        case .hrv: Palette.hrv
        case .restingHR: Palette.heartRate
        case .respiratoryRate: .cyan
        case .sleepPerformance: Palette.sleep
        case .strain: Palette.strain
        case .stress: .orange
        }
    }

    /// A fixed scale where the metric has one. Otherwise the scale fits the data (`ChartDomain.line`).
    var fixedDomain: ClosedRange<Double>? {
        switch self {
        case .recovery, .sleepPerformance, .stress: 0...100
        case .strain: 0...21
        case .hrv, .restingHR, .respiratoryRate: nil
        }
    }

    func value(_ point: DailyScorePoint) -> Double? {
        switch self {
        case .recovery: point.recovery
        case .hrv: point.hrvMs
        case .restingHR: point.restingHR
        case .respiratoryRate: point.respiratoryRate
        case .sleepPerformance: point.sleepPerformance
        case .strain: point.dayStrain
        case .stress: point.stressAverage
        }
    }

    /// The number without its unit: whole numbers, one decimal where the scale needs it.
    func number(_ value: Double) -> String {
        switch self {
        case .strain, .respiratoryRate: String(format: "%.1f", value)
        default: "\(Int(value.rounded()))"
        }
    }

    /// The number with its unit, e.g. "58 %" or "12.3 / 21".
    func text(_ value: Double) -> String {
        "\(number(value)) \(unit)"
    }
}

/// Recovery, HRV, resting HR, respiratory rate, sleep performance, strain and stress over 7, 30 or 90 days.
/// One chart at a time, with the average and the range of the chosen span and a dashed median line over the
/// whole 90 days loaded.
struct TrendsView: View {
    let environment: AppEnvironment
    let liveState: LiveState

    @State private var snapshot: HealthSnapshot?
    @State private var span: TrendSpan = .month
    @State private var metric: TrendMetric = .recovery
    @State private var selection: Date?
    @State private var refreshToken = 0

    /// The widest span. It is loaded once, and the shorter spans slice it.
    static let loadedDays = TrendSpan.quarter.rawValue

    private var series: [DailyScorePoint] {
        snapshot?.series ?? []
    }

    private var visible: [DailyScorePoint] {
        Array(series.suffix(span.rawValue))
    }

    private var points: [DayPoint] {
        guard let snapshot else { return [] }
        return visible.compactMap { point -> DayPoint? in
            guard let value = metric.value(point) else { return nil }
            return DayPoint(date: Date(epochMs: LocalTime.localTime(point.day, hour: 12, in: snapshot.timeZone)), value: value)
        }
    }

    /// Median over every loaded day with a value, for the dashed reference line.
    private var baseline: Double? {
        HealthMonitor.median(series.compactMap(metric.value))
    }

    private var average: Double? {
        TrendSeries.mean(points.map(\.value))
    }

    private var selectedPoint: DayPoint? {
        guard let selection else { return nil }
        return points.min { abs($0.date.timeIntervalSince(selection)) < abs($1.date.timeIntervalSince(selection)) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.s24) {
                VStack(alignment: .leading, spacing: Spacing.s12) {
                    TrendSpanPicker(span: $span)
                    Picker("Metric", selection: $metric) {
                        ForEach(TrendMetric.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("trends.metric")
                }
                chartCard
                summaryTiles
            }
            .pagePadding()
            .padding(.vertical, Spacing.s8)
            .redacted(reason: snapshot == nil ? .placeholder : [])
        }
        .dashboardBackground()
        .navigationTitle("Trends")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await environment.sync.runNow()
            refreshToken += 1
        }
        .task(id: refreshToken) {
            let nowMs = environment.clock.nowMs
            let loaded = try? await environment.database.writer.read { db in
                try HealthSnapshot.load(db, nowMs: nowMs, day: nil, seriesDays: Self.loadedDays)
            }
            if let loaded {
                snapshot = loaded
            }
        }
    }

    // MARK: Chart

    private var chartCard: some View {
        ChartCard(title: metric.label, footer: footer) {
            VStack(alignment: .leading, spacing: Spacing.s4) {
                Text(averageText)
                    .font(.metricValue)
                    .monospacedDigit()
                Text(readoutText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } chart: {
            if points.isEmpty, snapshot != nil {
                Text("No \(metric.label.lowercased()) in the last \(span.rawValue) days.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: Spacing.s48 * 3, alignment: .center)
            } else {
                chart
                    .frame(height: Spacing.s48 * 4)
            }
        }
    }

    private var chart: some View {
        Chart {
            if let baseline {
                RuleMark(y: .value("Median", baseline))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            ForEach(points) { point in
                LineMark(x: .value("Day", point.date, unit: .day), y: .value(metric.label, point.value))
                    .foregroundStyle(metric.tint)
                PointMark(x: .value("Day", point.date, unit: .day), y: .value(metric.label, point.value))
                    .foregroundStyle(metric.tint)
                    .symbolSize(Spacing.s16)
            }
            if let selectedPoint {
                RuleMark(x: .value("Selected", selectedPoint.date, unit: .day))
                    .foregroundStyle(.secondary.opacity(0.5))
            }
        }
        .chartYScale(domain: metric.fixedDomain ?? ChartDomain.line(points.map(\.value)))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisValueLabel()
                    .font(.caption2.monospacedDigit())
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    .font(.caption2.monospacedDigit())
            }
        }
        .chartXSelection(value: $selection)
        .accessibilityLabel("\(metric.label), \(span.label)")
        .accessibilityValue(averageText)
    }

    private var averageText: String {
        average.map { "Average \(metric.text($0))" } ?? "Average --"
    }

    /// The selected day with its exact value, or a hint while nothing is selected.
    private var readoutText: String {
        guard let selectedPoint, let snapshot else { return "Touch the chart to read a day" }
        let day = Date.label(selectedPoint.date, in: snapshot.timeZone)
        return "\(day) · \(metric.text(selectedPoint.value))"
    }

    private var footer: String {
        "Dashed line: \(TrendsView.loadedDays)-day median. Days without a value are left out."
    }

    // MARK: Summary

    private var summaryTiles: some View {
        let values = points.map(\.value)
        return HStack(spacing: Spacing.s12) {
            StatTile(title: "Min", value: values.min().map(metric.text) ?? "--")
            StatTile(title: "Average", value: average.map(metric.text) ?? "--")
            StatTile(title: "Max", value: values.max().map(metric.text) ?? "--")
        }
    }
}

private extension Date {
    /// A date for a readout, e.g. "Oct 20" in `timeZone`.
    static func label(_ date: Date, in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
