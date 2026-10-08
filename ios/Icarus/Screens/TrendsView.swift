import Metrics
import Store
import SwiftUI

/// Seven, 30 or 90 days of resting HR, nightly RMSSD, stress and calories, each against the period before it
/// (PLAN.md §14 row 11).
struct TrendsView: View {
    let environment: AppEnvironment

    @State private var span: TrendSpan = .week
    @State private var snapshot: Dashboard.TrendsSnapshot?

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
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.s16) {
                Picker("Span", selection: $span) {
                    ForEach(TrendSpan.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                lineCard(title: "Resting HR", series: restingSeries, unit: "bpm", tint: Palette.heartRate)
                lineCard(title: "Nightly RMSSD", series: rmssdSeries, unit: "ms", tint: Palette.hrv)
                stressCard
                calorieCard
            }
            .pagePadding()
            .padding(.vertical, Spacing.s8)
        }
        .dashboardBackground()
        .navigationTitle("Trends")
        .task(id: span) {
            // Twice the span: the first half is the previous period, for the change chips.
            let days = span.rawValue * 2
            for await value in environment.snapshots(every: .seconds(60), { db, nowMs in
                try Dashboard.trends(db, nowMs: nowMs, dayCount: days)
            }) {
                snapshot = value
            }
        }
    }

    // MARK: Cards

    private func lineCard(title: String, series: TrendSeries, unit: String, tint: Color) -> some View {
        ChartCard(title: title, footer: latestFooter(series, unit: unit)) {
            summary(series, unit: unit)
        } chart: {
            chartOrEmpty(series, unit: unit) {
                DayLineChart(points: series.points, tint: tint, average: series.average)
            }
        }
    }

    private var stressCard: some View {
        ChartCard(title: "Stress average", footer: latestFooter(stressSeries, unit: "")) {
            summary(stressSeries, unit: "")
        } chart: {
            chartOrEmpty(stressSeries, unit: "") {
                DayBarChart(
                    points: stressSeries.points,
                    color: { Palette.stress(StressBand.of(stress: Int($0.rounded()))) },
                    average: stressSeries.average
                )
            }
        }
    }

    private var calorieCard: some View {
        ChartCard(title: "Calories", footer: "Estimated. " + latestFooter(calorieSeries, unit: "kcal")) {
            summary(calorieSeries, unit: "kcal")
        } chart: {
            chartOrEmpty(calorieSeries, unit: "kcal") {
                DayBarChart(
                    points: calorieSeries.points,
                    color: { _ in Palette.caloriesActive },
                    average: calorieSeries.average
                )
            }
        }
    }

    private func summary(_ series: TrendSeries, unit: String) -> some View {
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

    @ViewBuilder
    private func chartOrEmpty<Content: View>(
        _ series: TrendSeries,
        unit: String,
        @ViewBuilder _ chart: () -> Content
    ) -> some View {
        if series.points.isEmpty {
            Text("No data for this span")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            chart()
                .frame(height: Spacing.s48 * 3)
                .accessibilityLabel("Chart, \(span.label)")
                .accessibilityValue(latestFooter(series, unit: unit))
        }
    }

    private func latestFooter(_ series: TrendSeries, unit: String) -> String {
        guard let latest = series.latest else { return "No data" }
        return "Latest \(Format.number(latest, unit: unit))"
    }

    // MARK: Series

    private var timeZone: TimeZone {
        snapshot?.context.timeZone ?? Dashboard.fallbackZone
    }

    private var restingSeries: TrendSeries {
        series(\.restingHR)
    }

    private var rmssdSeries: TrendSeries {
        series(\.rmssdNight)
    }

    private var stressSeries: TrendSeries {
        series(\.stressAverage)
    }

    private var calorieSeries: TrendSeries {
        series(\.kcalTotal)
    }

    private func series(_ value: KeyPath<DaySummary, Double?>) -> TrendSeries {
        TrendSeries.make(
            days: snapshot?.days ?? [],
            timeZone: timeZone,
            value: value,
            currentCount: span.rawValue
        )
    }
}
