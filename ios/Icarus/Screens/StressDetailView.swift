import Metrics
import Store
import SwiftUI

/// One read of the stress screen: the summary, the 24-hour timeline and the calibration progress.
private struct StressScreenData: Sendable {
    let snapshot: Dashboard.StressSnapshot
    let timeline: [StressTimelinePoint]
    let calibration: StressCalibrationProgress
    let fromMs: Int64
    let nowMs: Int64
    /// Stimulant windows for yesterday and today; the chart clips them to the last 24 h.
    let medication: [MedicationWindow]
}

/// Stress now, over 24 h and over 7, 30 or 90 days, with RMSSD and sqrt(Baevsky SI) (PLAN.md §14 row 9).
struct StressDetailView: View {
    let environment: AppEnvironment

    @State private var data: StressScreenData?
    @State private var span: TrendSpan = .week
    @State private var trends: Dashboard.TrendsSnapshot?
    @State private var showsMethod = false

    private var snapshot: Dashboard.StressSnapshot? {
        data?.snapshot
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.s16) {
                DashboardCard(title: "Now", symbol: "gauge.with.dots.needle.67percent", tint: .orange) {
                    HStack(spacing: Spacing.s24) {
                        StressGauge(value: latest?.stress)
                            .frame(width: Spacing.s48 * 2, height: Spacing.s48 * 2)
                        VStack(alignment: .leading, spacing: Spacing.s4) {
                            Text(currentValue)
                                .font(.metricValue)
                                .monospacedDigit()
                                .liveNumberTransition()
                            if let band = currentBand {
                                Text(band)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Text("Estimated")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let data, !data.calibration.days.isEmpty, !data.calibration.isCalibrated {
                                Text("\(data.calibration.qualifyingDays) of \(data.calibration.requiredDays) days")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }

                ChartCard(title: "Last 24 h", footer: "Each point is a scored minute. Calibrating, exertion and insufficient minutes are gaps.") {
                    StressLegend()
                } chart: {
                    if let data, data.timeline.contains(where: { $0.stress != nil }) {
                        StressTimelineChart(
                            points: data.timeline,
                            fromMs: data.fromMs,
                            toMs: data.nowMs,
                            medicationWindows: data.medication
                        )
                        .frame(height: Spacing.s48 * 3)
                    } else {
                        Text("No stress values yet")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                if let data, !data.medication.isEmpty {
                    MedicationLegend()
                }

                if let data {
                    DashboardCard(title: "Calibration", symbol: "slider.horizontal.3", tint: .orange) {
                        StressCalibrationDetail(
                            progress: data.calibration,
                            state: data.snapshot.latest?.state,
                            timeZone: data.snapshot.context.timeZone
                        )
                    }
                }

                ChartCard(title: "Stress, \(span.label)", footer: stressFooter) {
                    VStack(alignment: .leading, spacing: Spacing.s12) {
                        TrendSpanPicker(span: $span)
                        TrendSummary(series: stressTrend, unit: "")
                    }
                } chart: {
                    if stressTrend.points.isEmpty {
                        Text("No data for this span")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        DayBarChart(
                            points: stressTrend.points,
                            color: { Palette.stress(StressBand.of(stress: Int($0.rounded()))) },
                            average: stressTrend.average
                        )
                        .frame(height: Spacing.s48 * 3)
                        .accessibilityLabel("Stress, \(span.label) daily averages")
                        .accessibilityValue(stressFooter)
                    }
                }

                ChartCard(title: "RMSSD, \(span.label)", footer: rmssdTrend.latestFooter(unit: "ms")) {
                    TrendSummary(series: rmssdTrend, unit: "ms")
                } chart: {
                    if rmssdTrend.points.isEmpty {
                        Text("No data for this span")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        DayLineChart(points: rmssdTrend.points, tint: Palette.hrv, average: rmssdTrend.average)
                            .frame(height: Spacing.s48 * 2)
                            .accessibilityLabel("Nightly RMSSD, \(span.label)")
                            .accessibilityValue(rmssdTrend.latestFooter(unit: "ms"))
                    }
                }

                HStack(spacing: Spacing.s12) {
                    StatTile(title: "RMSSD", value: snapshot?.rmssd.map { Format.ms($0) } ?? "--")
                    StatTile(title: "Sqrt Baevsky SI", value: snapshot?.baevskySqrt.map(Self.decimal) ?? "--")
                }

                Button("How Stress Is Estimated") {
                    showsMethod = true
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .pagePadding()
            .padding(.vertical, Spacing.s8)
        }
        .dashboardBackground()
        .navigationTitle("Stress")
        .task {
            for await value in environment.snapshots(every: .seconds(15), { db, nowMs in
                let snapshot = try Dashboard.stress(db, nowMs: nowMs)
                let fromMs = nowMs - 24 * 60 * LocalTime.msPerMinute
                return StressScreenData(
                    snapshot: snapshot,
                    timeline: try Dashboard.stressTimeline(db, nowMs: nowMs, fromMs: fromMs),
                    calibration: try Dashboard.stressCalibration(db, nowMs: nowMs, context: snapshot.context),
                    fromMs: fromMs,
                    nowMs: nowMs,
                    medication: try db.medicationWindows(
                        from: LocalTime.adding(days: -1, to: snapshot.context.today),
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
        .sheet(isPresented: $showsMethod) {
            StressMethodSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var latest: MinuteMetricRow? {
        snapshot?.latest
    }

    private var stressTrend: TrendSeries {
        TrendSeries.make(
            days: trends?.days ?? [],
            timeZone: trends?.context.timeZone ?? Dashboard.fallbackZone,
            value: \.stressAverage,
            currentCount: span.rawValue
        )
    }

    private var rmssdTrend: TrendSeries {
        TrendSeries.make(
            days: trends?.days ?? [],
            timeZone: trends?.context.timeZone ?? Dashboard.fallbackZone,
            value: \.rmssdNight,
            currentCount: span.rawValue
        )
    }

    private var stressFooter: String {
        "Daily averages. " + stressTrend.latestFooter(unit: "")
    }

    private var currentValue: String {
        if let stress = latest?.stress { return "\(stress)" }
        return Format.stressState(latest?.state ?? .insufficient)
    }

    private var currentBand: String? {
        latest?.stress.map { Format.stressBand($0) }
    }

    private static func decimal(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

/// Method and caveats (PLAN.md §8.3), shown from a row rather than as a page subtitle (PLAN.md §15.1).
private struct StressMethodSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Method") {
                    Text("Stress compares your heart rate and RMSSD in 5-minute windows with your own awake windows from the last 14 days.")
                    Text("A day qualifies with 24 awake five-minute windows (2 h) of valid R-R, outside sleep and exertion.")
                    Text("Values need 7 qualifying days before they appear. Until then the state reads Calibrating.")
                    Text("Without R-R, 7 days of heart-rate windows can score an HR-only fallback. It omits HRV, so it is less specific.")
                }
                Section("Limits") {
                    Text("Band readings are less precise than an ECG. Motion adds noise. Windows above 40 % heart-rate reserve are excluded as exertion.")
                    Text("Caffeine, alcohol, illness and posture also change HRV.")
                    Text("This is an estimate, not WHOOP's Stress Monitor, and not a medical measure.")
                }
            }
            .navigationTitle("Stress Method")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
