import Metrics
import Store
import SwiftUI
import SyncKit

/// Destinations pushed from Today's cards (PLAN.md §14 rows 8-10).
enum TodayDestination: Hashable {
    case heartRate
    case stress
    case calories
    case sync
}

/// The Today dashboard: live heart rate, four metric tiles, stress and zones for the day, and band and sync status.
struct TodayView: View {
    let environment: AppEnvironment
    let liveState: LiveState

    @State private var snapshot: Dashboard.TodaySnapshot?

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.s16) {
                if environment.sync.status.phase == .needsRepair {
                    repairCard
                }
                if environment.storageFailed {
                    storageCard
                }
                heroCard
                metricGrid
                stressCard
                zonesCard
                statusCard
            }
            .pagePadding()
            .padding(.vertical, Spacing.s8)
        }
        .dashboardBackground()
        .refreshable {
            await environment.sync.runNow()
        }
        .navigationTitle("Today")
        .navigationDestination(for: TodayDestination.self) { destination in
            switch destination {
            case .heartRate: HeartRateDetailView(environment: environment)
            case .stress: StressDetailView(environment: environment)
            case .calories: CaloriesDetailView(environment: environment)
            case .sync: SyncView(environment: environment)
            }
        }
        .task {
            let clock = environment.clock
            do {
                for try await value in environment.database.observe({ try Dashboard.today($0, nowMs: clock.nowMs) }) {
                    snapshot = value
                }
            } catch {
                snapshot = nil
            }
        }
    }

    // MARK: Cards

    private var repairCard: some View {
        NavigationLink {
            ServerView(sync: environment.sync)
        } label: {
            DashboardCard(
                title: "Re-pair this iPhone",
                symbol: "exclamationmark.triangle.fill",
                tint: Palette.warn,
                showsChevron: true
            ) {
                Text("The server rejected this iPhone. Pair again to resume sync.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private var storageCard: some View {
        DashboardCard(title: "Not saved", symbol: "externaldrive.badge.exclamationmark", tint: Palette.error) {
            Text("Data is not saved on this launch.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var heroCard: some View {
        NavigationLink(value: TodayDestination.heartRate) {
            DashboardCard(
                title: "Heart rate",
                symbol: "heart.fill",
                tint: Palette.heartRate,
                showsChevron: true,
                pulses: liveState.isStreaming
            ) {
                HStack(alignment: .firstTextBaseline) {
                    bpmText
                    Spacer(minLength: Spacing.s8)
                    StatusPill.link(liveState)
                }
                HRAreaChart(points: sparklinePoints, average: nil, selection: .constant(nil))
                    .frame(height: Spacing.s48 * 2)
                    .allowsHitTesting(false)
                    .accessibilityLabel("Heart rate, last 15 minutes")
                    .accessibilityValue(rangeText)
                HStack {
                    Text("Last 15 min")
                    Spacer(minLength: Spacing.s8)
                    Text(rangeText)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var bpmText: some View {
        if let bpm = liveState.latestBPM {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s4) {
                Text("\(bpm)")
                    .font(.heroValue)
                    .monospacedDigit()
                    .liveNumberTransition()
                    .stateAnimation(bpm)
                    .accessibilityIdentifier("today.hrValue")
                Text("bpm")
                    .font(.metricUnit)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("--")
                .font(.heroValue)
                .foregroundStyle(.secondary)
        }
    }

    private var metricGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: Spacing.s16),
                GridItem(.flexible(), spacing: Spacing.s16),
            ],
            spacing: Spacing.s16
        ) {
            NavigationLink(value: TodayDestination.heartRate) {
                MetricTile(
                    title: "Resting HR",
                    symbol: "bed.double.fill",
                    tint: Palette.sleep,
                    value: restingValue,
                    unit: restingValue == "--" ? nil : "bpm",
                    change: restingSeries.change,
                    changeUnit: "bpm"
                ) {
                    MiniSparkline(points: restingWeek.points, tint: Palette.sleep)
                }
            }
            .buttonStyle(.plain)

            NavigationLink(value: TodayDestination.stress) {
                MetricTile(
                    title: "HRV",
                    symbol: "waveform.path.ecg",
                    tint: Palette.hrv,
                    value: hrvValue,
                    unit: hrvValue == "--" ? nil : "ms",
                    change: hrvSeries.change,
                    changeUnit: "ms"
                ) {
                    MiniSparkline(points: hrvWeek.points, tint: Palette.hrv)
                }
            }
            .buttonStyle(.plain)

            NavigationLink(value: TodayDestination.stress) {
                MetricTile(
                    title: "Stress",
                    symbol: "gauge.with.dots.needle.67percent",
                    tint: Palette.stressModerate,
                    value: stressValue,
                    valueIdentifier: "today.stressValue"
                ) {
                    HStack(spacing: Spacing.s8) {
                        StressGauge(value: latestStress)
                            .frame(width: MetricTileLayout.visualHeight, height: MetricTileLayout.visualHeight)
                        if let band = stressCaption {
                            Text(band)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .buttonStyle(.plain)

            NavigationLink(value: TodayDestination.calories) {
                MetricTile(
                    title: "Calories",
                    symbol: "flame.fill",
                    tint: Palette.caloriesActive,
                    value: caloriesValue,
                    unit: caloriesValue == "--" ? nil : "kcal",
                    caption: "Estimated",
                    valueIdentifier: "today.caloriesValue"
                ) {
                    HStack(spacing: Spacing.s12) {
                        RingProgress(fraction: activeShare, summary: "Active share of calories", lineWidth: Spacing.s8) {
                            EmptyView()
                        }
                        .frame(width: MetricTileLayout.visualHeight, height: MetricTileLayout.visualHeight)
                        Text(activeText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var stressCard: some View {
        NavigationLink(value: TodayDestination.stress) {
            DashboardCard(
                title: "Stress today",
                symbol: "gauge.with.dots.needle.67percent",
                tint: .orange,
                showsChevron: true
            ) {
                if let buckets = snapshot?.stressBuckets, !buckets.isEmpty {
                    StressBarChart(buckets: buckets)
                        .frame(height: Spacing.s48 * 2)
                        .allowsHitTesting(false)
                    StressLegend()
                } else {
                    Text("No stress values yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var zonesCard: some View {
        NavigationLink(value: TodayDestination.heartRate) {
            DashboardCard(
                title: "Zones today",
                symbol: "figure.run",
                tint: .green,
                showsChevron: true
            ) {
                if let zones = snapshot?.zones, zones.contains(where: { $0.minutes > 0 }) {
                    ZoneBar(zones: zones)
                } else {
                    Text("Zones need a profile and a night of data.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var statusCard: some View {
        NavigationLink(value: TodayDestination.sync) {
            DashboardCard(
                title: "Band and sync",
                symbol: "antenna.radiowaves.left.and.right",
                tint: .blue,
                showsChevron: true
            ) {
                HStack(spacing: Spacing.s8) {
                    StatusPill.link(liveState)
                    if let battery = liveState.batteryPercent {
                        StatusPill(text: Format.percent(battery), symbol: Format.batterySymbol(battery))
                    }
                    Spacer()
                }
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    HStack(spacing: Spacing.s8) {
                        Text("Last sync")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: Spacing.s8)
                        StatusPill(
                            text: lastSyncText(now: context.date),
                            symbol: "arrow.triangle.2.circlepath",
                            tint: Palette.sync(environment.sync.status.phase)
                        )
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Values

    private var sparklinePoints: [HRPoint] {
        let raw = (snapshot?.sparkline ?? []).map { HRPoint(date: $0.date, bpm: Double($0.bpm)) }
        return HRPoint.averaged(raw, bucket: 15)
    }

    private var rangeText: String {
        let values = (snapshot?.sparkline ?? []).map(\.bpm)
        guard let low = values.min(), let high = values.max() else { return "No samples" }
        return "Range \(low)-\(high) bpm"
    }

    private var week: [DaySummary] {
        snapshot?.week ?? []
    }

    private var restingSeries: TrendSeries {
        TrendSeries.make(days: week, timeZone: timeZone, value: \.restingHR, currentCount: 1)
    }

    /// Seven days for the sparklines. `restingSeries` and `hrvSeries` cover today only, for the value and the change.
    private var restingWeek: TrendSeries {
        TrendSeries.make(days: week, timeZone: timeZone, value: \.restingHR, currentCount: 7)
    }

    private var hrvSeries: TrendSeries {
        TrendSeries.make(days: week, timeZone: timeZone, value: \.rmssdNight, currentCount: 1)
    }

    private var hrvWeek: TrendSeries {
        TrendSeries.make(days: week, timeZone: timeZone, value: \.rmssdNight, currentCount: 7)
    }

    private var timeZone: TimeZone {
        snapshot?.context.timeZone ?? Dashboard.fallbackZone
    }

    private var restingValue: String {
        guard let value = restingSeries.latest ?? snapshot?.context.restingHR else { return "--" }
        return "\(Int(value.rounded()))"
    }

    private var hrvValue: String {
        guard let value = hrvSeries.latest else { return "--" }
        return "\(Int(value.rounded()))"
    }

    private var latestStress: Int? {
        snapshot?.latestMinute?.stress
    }

    private var stressValue: String {
        if let latest = latestStress { return "\(latest)" }
        return Format.stressState(snapshot?.latestMinute?.state ?? .insufficient)
    }

    private var stressCaption: String? {
        guard let latest = latestStress else { return nil }
        return Format.stressBand(latest)
    }

    private var caloriesValue: String {
        guard let total = snapshot?.today?.kcalTotal else { return "--" }
        return "\(Int(total.rounded()))"
    }

    private var activeShare: Double {
        guard let total = snapshot?.today?.kcalTotal, total > 0, let active = snapshot?.today?.kcalActive else { return 0 }
        return active / total
    }

    private var activeText: String {
        guard let active = snapshot?.today?.kcalActive else { return "Active --" }
        return "Active \(Int(active.rounded())) kcal"
    }

    private func lastSyncText(now: Date) -> String {
        let status = environment.sync.status
        if status.phase == .notPaired { return "Not paired" }
        guard let last = status.lastSuccessAt else { return "Not synced" }
        return DataAge.text(seconds: now.timeIntervalSince(last))
    }
}
