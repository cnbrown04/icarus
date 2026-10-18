import Store
import SwiftUI

/// Heart rate over 1 h to 7 d, with zones and min, average and max, and resting HR over 30 days (PLAN.md §14 row 8).
struct HeartRateDetailView: View {
    let environment: AppEnvironment

    @State private var range: Dashboard.HeartRateRange = .hour
    @State private var snapshot: Dashboard.HeartRateSnapshot?
    @State private var trend = TrendSeries.empty
    @State private var selection: Date?

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.s16) {
                Picker("Range", selection: $range) {
                    ForEach(Dashboard.HeartRateRange.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                ChartCard(title: "Heart rate", footer: rangeFooter) {
                    Text(snapshot?.average.map { Format.number($0, unit: "bpm") } ?? "--")
                        .font(.metricValue)
                        .monospacedDigit()
                } chart: {
                    HRAreaChart(points: points, average: snapshot?.average, selection: $selection)
                        .frame(height: Spacing.s48 * 3)
                        .accessibilityLabel("Heart rate, \(range.label)")
                        .accessibilityValue(summary)
                }

                HStack(spacing: Spacing.s12) {
                    StatTile(title: "Min", value: snapshot?.minimum.map { Format.bpm($0) } ?? "--")
                    StatTile(title: "Average", value: snapshot?.average.map { Format.bpm($0) } ?? "--")
                    StatTile(title: "Max", value: snapshot?.maximum.map { Format.bpm($0) } ?? "--")
                }

                DashboardCard(title: "Zones", symbol: "figure.run", tint: .green) {
                    if let zones = snapshot?.zones, zones.contains(where: { $0.minutes > 0 }) {
                        ZoneBar(zones: zones)
                    } else {
                        Text("Zones need a profile and a night of data.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                ChartCard(title: "Resting HR, 30 days", footer: trendFooter) {
                    Text(trend.latest.map { Format.number($0, unit: "bpm") } ?? "--")
                        .font(.metricValue)
                        .monospacedDigit()
                } chart: {
                    if trend.points.isEmpty {
                        Text("No resting HR yet")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        DayLineChart(points: trend.points, tint: Palette.heartRate, average: trend.average)
                            .frame(height: Spacing.s48 * 3)
                            .accessibilityLabel("Resting HR, 30 days")
                    }
                }
            }
            .pagePadding()
            .padding(.vertical, Spacing.s8)
        }
        .dashboardBackground()
        .navigationTitle("Heart rate")
        .task(id: range) {
            let selected = range
            for await value in environment.snapshots(every: .seconds(15), { db, nowMs in
                try Dashboard.heartRate(db, nowMs: nowMs, range: selected)
            }) {
                snapshot = value
            }
        }
        .task {
            for await value in environment.snapshots(every: .seconds(60), { db, nowMs in
                try Dashboard.trends(db, nowMs: nowMs, dayCount: 30)
            }) {
                trend = TrendSeries.make(
                    days: value.days,
                    timeZone: value.context.timeZone,
                    value: \.restingHR,
                    currentCount: 30
                )
            }
        }
    }

    private var points: [HRPoint] {
        (snapshot?.buckets ?? []).map { HRPoint(date: Date(epochMs: $0.startMs), bpm: $0.avg) }
    }

    private var summary: String {
        guard let average = snapshot?.average else { return "No heart rate in this range" }
        return "Average \(Format.bpm(average))"
    }

    private var rangeFooter: String? {
        guard let low = snapshot?.minimum, let high = snapshot?.maximum else { return nil }
        return "Range \(low)-\(high) bpm"
    }

    private var trendFooter: String {
        guard let average = trend.average else { return "No data" }
        return "Average \(Format.number(average, unit: "bpm")) over 30 days"
    }
}
