import Metrics
import Store
import SwiftUI

/// The Health tab root: the Health Monitor summary, today's recovery, the trends entry, and links to the
/// heart-rate, stress and calorie detail screens. Not wired into `RootView` yet (the Shell stream does that).
struct HealthTabView: View {
    let environment: AppEnvironment
    let liveState: LiveState

    @State private var snapshot: HealthSnapshot?

    /// Today on the device clock until the first snapshot names the profile's day.
    private var today: LocalDay {
        snapshot?.day ?? LocalTime.localDay(containing: environment.clock.nowMs, in: Dashboard.fallbackZone)
    }

    private var readout: RecoveryReadout {
        RecoveryReadout(outcome: snapshot?.scores.recovery)
    }

    private var monitorSummary: HealthMonitor.Summary? {
        guard let statuses = snapshot?.vitals.statuses else { return nil }
        return HealthMonitor.summary(statuses)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.s24) {
                monitorLink
                recoveryLink
                trendsLink
                detailLinks
            }
            .pagePadding()
            .padding(.vertical, Spacing.s8)
            .redacted(reason: snapshot == nil ? .placeholder : [])
        }
        .dashboardBackground()
        .navigationTitle("Health")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await environment.sync.runNow()
        }
        .task {
            for await value in environment.snapshots(every: .seconds(60), { db, nowMs in
                try HealthSnapshot.load(db, nowMs: nowMs, day: nil, seriesDays: 0)
            }) {
                snapshot = value
            }
        }
    }

    // MARK: Cards

    private var monitorLink: some View {
        NavigationLink {
            HealthMonitorView(environment: environment, liveState: liveState, day: today)
        } label: {
            DashboardCard(title: "Health Monitor", symbol: "waveform.path.ecg", tint: Palette.heartRate, showsChevron: true) {
                VStack(alignment: .leading, spacing: Spacing.s4) {
                    Text(monitorHeadline)
                        .font(.metricValue)
                        .monospacedDigit()
                    Text(monitorCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the Health Monitor")
    }

    private var monitorHeadline: String {
        guard let summary = monitorSummary, summary.evaluated > 0 else {
            return snapshot == nil ? "--" : "Calibrating"
        }
        return "\(summary.inRange) of \(summary.evaluated) in range"
    }

    private var monitorCaption: String {
        guard let snapshot else { return "" }
        if snapshot.vitals.tonight.isEmpty {
            return "No main sleep ended today yet"
        }
        if (monitorSummary?.evaluated ?? 0) == 0 {
            return "\(snapshot.vitals.priorNights)/\(HealthMonitor.minimumNights) nights for a personal range"
        }
        return "Tonight against your last \(HealthMonitor.baselineNights) nights"
    }

    private var recoveryLink: some View {
        NavigationLink {
            RecoveryDetailView(environment: environment, liveState: liveState, day: today)
        } label: {
            DashboardCard(title: "Recovery", symbol: "bolt.heart.fill", tint: readout.tint, showsChevron: true) {
                VStack(alignment: .leading, spacing: Spacing.s4) {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.s4) {
                        Text(readout.value)
                            .font(.metricValue)
                            .monospacedDigit()
                        if readout.hasScore {
                            Text("%")
                                .font(.metricUnit)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(readout.caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(readout.summary)
        .accessibilityHint("Opens recovery")
    }

    private var trendsLink: some View {
        NavigationLink {
            TrendsView(environment: environment, liveState: liveState)
        } label: {
            DashboardCard(title: "Trends", symbol: "chart.line.uptrend.xyaxis", tint: Palette.sleep, showsChevron: true) {
                Text("Recovery, HRV, resting HR, respiratory rate, sleep performance, strain and stress")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens trends")
    }

    /// Heart rate, stress and calories stay on their own detail screens. Each row links there.
    private var detailLinks: some View {
        VStack(alignment: .leading, spacing: Spacing.s12) {
            NavigationLink {
                HeartRateDetailView(environment: environment)
            } label: {
                detailRow(title: "Heart rate", symbol: "heart.fill", tint: Palette.heartRate)
            }
            .buttonStyle(.plain)
            Divider()
            NavigationLink {
                StressDetailView(environment: environment)
            } label: {
                detailRow(title: "Stress", symbol: "gauge.with.dots.needle.67percent", tint: .orange)
            }
            .buttonStyle(.plain)
            Divider()
            NavigationLink {
                CaloriesDetailView(environment: environment)
            } label: {
                detailRow(title: "Calories", symbol: "flame.fill", tint: .orange)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.s16)
        .cardBackground()
    }

    private func detailRow(title: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: Spacing.s12) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: Spacing.s24)
            Text(title)
                .font(.body)
            Spacer(minLength: Spacing.s8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}
