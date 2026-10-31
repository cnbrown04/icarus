import Metrics
import Store
import SwiftUI

/// Everything the heart-rate screen reads in one snapshot: the selected range, plus today's zone
/// timeline for the day chart above the per-zone bars.
private struct HeartRateScreenData: Sendable {
    let snapshot: Dashboard.HeartRateSnapshot
    let dayStartMs: Int64
    let dayTimeline: HRZoneTimeline
    /// Stimulant windows for the last 7 days; the chart clips them to the selected range.
    let medication: [MedicationWindow]
}

private extension Dashboard.HeartRateRange {
    /// How far back the selected range reaches, in ms.
    var spanMs: Int64 {
        switch self {
        case .hour: 60 * LocalTime.msPerMinute
        case .sixHours: 6 * 60 * LocalTime.msPerMinute
        case .day: 24 * 60 * LocalTime.msPerMinute
        case .week: 7 * 24 * 60 * LocalTime.msPerMinute
        }
    }
}

/// Heart rate over 1 h to 7 d, with zones and min, average and max, and resting HR over 7, 30 or 90 days
/// (PLAN.md §14 row 8).
struct HeartRateDetailView: View {
    let environment: AppEnvironment

    @State private var range: Dashboard.HeartRateRange = .hour
    @State private var span: TrendSpan = .month
    @State private var data: HeartRateScreenData?
    @State private var trends: Dashboard.TrendsSnapshot?
    @State private var selection: Date?

    private var snapshot: Dashboard.HeartRateSnapshot? {
        data?.snapshot
    }

    private var dayTimeline: HRZoneTimeline {
        data?.dayTimeline ?? .empty
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.s16) {
                Picker("Range", selection: $range) {
                    ForEach(Dashboard.HeartRateRange.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                ChartCard(title: "Heart Rate", footer: rangeFooter) {
                    Text(snapshot?.average.map { Format.number($0, unit: "bpm") } ?? "--")
                        .font(.metricValue)
                        .monospacedDigit()
                } chart: {
                    HRAreaChart(
                        points: points,
                        average: snapshot?.average,
                        selection: $selection,
                        medicationWindows: data?.medication ?? [],
                        xDomain: visibleDomain
                    )
                    .frame(height: Spacing.s48 * 3)
                    .accessibilityLabel("Heart rate, \(range.label)")
                    .accessibilityValue(summary)
                }
                if let data, !data.medication.isEmpty {
                    MedicationLegend()
                }

                HStack(spacing: Spacing.s12) {
                    StatTile(title: "Min", value: snapshot?.minimum.map { Format.bpm($0) } ?? "--")
                    StatTile(title: "Average", value: snapshot?.average.map { Format.bpm($0) } ?? "--")
                    StatTile(title: "Max", value: snapshot?.maximum.map { Format.bpm($0) } ?? "--")
                }

                DashboardCard(title: "Zones", symbol: "figure.run", tint: .green) {
                    if let data, !data.dayTimeline.runs.isEmpty {
                        Text("Today, by minute")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ZoneTimelineChart(
                            timeline: data.dayTimeline,
                            fromMs: data.dayStartMs,
                            toMs: data.snapshot.context.nowMs
                        )
                        .frame(height: Spacing.s48 * 2 + Spacing.s16)
                    }
                    if let zones = snapshot?.zones, zones.contains(where: { $0.minutes > 0 }) {
                        Text("Minutes by zone, \(range.label)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ZoneBar(zones: zones)
                    } else if data == nil || dayTimeline.runs.isEmpty {
                        Text("Zones need a profile and a night of data.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                ChartCard(title: "Resting HR", footer: restingFooter) {
                    VStack(alignment: .leading, spacing: Spacing.s12) {
                        TrendSpanPicker(span: $span)
                        TrendSummary(series: restingTrend, unit: "bpm")
                    }
                } chart: {
                    if restingTrend.points.isEmpty {
                        Text("No resting HR for this span")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        DayLineChart(points: restingTrend.points, tint: Palette.heartRate, average: restingTrend.average)
                            .frame(height: Spacing.s48 * 3)
                            .accessibilityLabel("Resting HR, \(span.label)")
                            .accessibilityValue(restingFooter)
                    }
                }
            }
            .pagePadding()
            .padding(.vertical, Spacing.s8)
        }
        .dashboardBackground()
        .navigationTitle("Heart Rate")
        .task(id: range) {
            let selected = range
            for await value in environment.snapshots(every: .seconds(15), { db, nowMs in
                let snapshot = try Dashboard.heartRate(db, nowMs: nowMs, range: selected)
                let dayStart = LocalTime.localTime(
                    snapshot.context.today,
                    hour: 0,
                    in: snapshot.context.timeZone
                )
                return HeartRateScreenData(
                    snapshot: snapshot,
                    dayStartMs: dayStart,
                    dayTimeline: try Dashboard.hrZoneTimeline(
                        db, nowMs: nowMs, fromMs: dayStart, context: snapshot.context
                    ),
                    medication: try db.medicationWindows(
                        from: LocalTime.adding(days: -7, to: snapshot.context.today),
                        to: snapshot.context.today,
                        in: snapshot.context.timeZone
                    )
                )
            }) {
                data = value
            }
        }
        .task(id: span) {
            let days = span.loadedDayCount
            for await value in environment.snapshots(every: .seconds(60), { db, nowMs in
                try Dashboard.trends(db, nowMs: nowMs, dayCount: days)
            }) {
                trends = value
            }
        }
    }

    private var points: [HRPoint] {
        (snapshot?.buckets ?? []).map { HRPoint(date: Date(epochMs: $0.startMs), bpm: $0.avg) }
    }

    /// The selected range ending now, so shaded windows clip to it.
    private var visibleDomain: ClosedRange<Date>? {
        guard let nowMs = snapshot?.context.nowMs else { return nil }
        return Date(epochMs: nowMs - range.spanMs)...Date(epochMs: nowMs)
    }

    private var summary: String {
        guard let average = snapshot?.average else { return "No heart rate in this range" }
        return "Average \(Format.bpm(average))"
    }

    private var rangeFooter: String? {
        guard let low = snapshot?.minimum, let high = snapshot?.maximum else { return nil }
        return "Range \(low)-\(high) bpm"
    }

    private var restingFooter: String {
        guard let average = restingTrend.average else { return "No data for \(span.label)" }
        return "Average \(Format.number(average, unit: "bpm")) over \(span.rawValue) days. "
            + restingTrend.latestFooter(unit: "bpm")
    }

    private var restingTrend: TrendSeries {
        TrendSeries.make(
            days: trends?.days ?? [],
            timeZone: trends?.context.timeZone ?? Dashboard.fallbackZone,
            value: \.restingHR,
            currentCount: span.rawValue
        )
    }
}
