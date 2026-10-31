import Metrics
import Store
import SwiftUI

/// The Health tab root: today's resting HR, HRV and stress, the stress timeline, the Health Monitor summary, today's
/// recovery, the trends and journal insights entries, and links to the heart-rate, stress and calorie detail screens.
struct HealthTabView: View {
    let environment: AppEnvironment
    let liveState: LiveState

    @State private var snapshot: HealthSnapshot?
    @State private var todayVitals: HealthTodaySnapshot?

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
                todayVitalsRow
                stressTodayCard
                monitorLink
                recoveryLink
                trendsLink
                journalInsightsLink
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
        .task {
            let clock = environment.clock
            do {
                for try await value in environment.database.observe({ try HealthTodaySnapshot.load($0, nowMs: clock.nowMs) }) {
                    todayVitals = value
                }
            } catch {
                todayVitals = nil
            }
        }
    }

    // MARK: Today

    /// Resting HR, HRV and stress: the calibrating vitals row that used to sit on Home. Each tile opens its detail.
    private var todayVitalsRow: some View {
        HStack(alignment: .top, spacing: Spacing.s8) {
            NavigationLink {
                HeartRateDetailView(environment: environment)
            } label: {
                HomeVitalTile(
                    title: "Resting HR",
                    symbol: "heart.fill",
                    tint: Palette.sleep,
                    value: todayVitals?.restingHR.map { "\(Int($0.rounded()))" } ?? "—",
                    unit: todayVitals?.restingHR == nil ? nil : "bpm",
                    caption: todayVitals?.restingHR == nil ? "No data yet" : "Overnight low",
                    accessibilityLabel: "Resting heart rate",
                    accessibilityValue: todayVitals?.restingHR.map { Format.bpm($0) + ", overnight low" } ?? "No data yet"
                )
            }
            .buttonStyle(.plain)

            NavigationLink {
                StressDetailView(environment: environment)
            } label: {
                HomeVitalTile(
                    title: "HRV",
                    symbol: "waveform.path.ecg",
                    tint: Palette.hrv,
                    value: todayVitals?.rmssd.map { "\(Int($0.rounded()))" } ?? "—",
                    unit: todayVitals?.rmssd == nil ? nil : "ms",
                    caption: todayVitals?.rmssd == nil ? "No data yet" : "RMSSD",
                    accessibilityLabel: "Heart rate variability",
                    accessibilityValue: todayVitals?.rmssd.map { Format.ms($0) + ", last night" } ?? "No data yet"
                )
            }
            .buttonStyle(.plain)

            NavigationLink {
                StressDetailView(environment: environment)
            } label: {
                HomeVitalTile(
                    title: "Stress",
                    symbol: "gauge.with.dots.needle.67percent",
                    tint: stressTint,
                    value: todayVitals?.latestStress.map { "\($0)" } ?? "—",
                    caption: stressCaption,
                    captionTint: stressCaptionTint,
                    accessibilityLabel: "Stress",
                    accessibilityValue: todayVitals?.latestStress.map { "\($0), \(Format.stressBand($0))" } ?? stressCaption,
                    identifier: "health.stressValue"
                )
            }
            .buttonStyle(.plain)
        }
    }

    /// Today's stress timeline with the stimulant windows shaded, and the minutes in each band.
    private var stressTodayCard: some View {
        NavigationLink {
            StressDetailView(environment: environment)
        } label: {
            DashboardCard(title: "Stress today", symbol: "gauge.with.dots.needle.67percent", tint: .orange, showsChevron: true) {
                if let today = todayVitals {
                    if today.stressDay.sampleMinutes > 0 {
                        StressTimelineChart(
                            points: today.stressTimeline,
                            fromMs: today.dayStartMs,
                            toMs: today.nowMs,
                            medicationWindows: today.medication
                        )
                        .frame(height: Spacing.s48 * 2)
                        .allowsHitTesting(false)
                        if !stressBandSegments(today).isEmpty {
                            MinuteStrip(
                                segments: stressBandSegments(today),
                                accessibilityLabel: "Minutes in each stress band",
                                accessibilityValue: stressBandAccessibility(today)
                            )
                        }
                        Text(stressSummary(today.stressDay))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        if !today.medication.isEmpty {
                            Text("Shaded: stimulant active (estimated)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("No stress values yet")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No stress values yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var journalInsightsLink: some View {
        NavigationLink {
            JournalInsightsView(environment: environment)
        } label: {
            DashboardCard(title: "Journal insights", symbol: "book.closed.fill", tint: Palette.sleep, showsChevron: true) {
                Text("Next-morning recovery and sleep on days with and without each habit")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens journal insights")
    }

    private var stressTint: Color {
        todayVitals?.latestStress.map { Palette.stress(StressBand.of(stress: $0)) } ?? Palette.stressModerate
    }

    /// The band when there is a value, else the shortest honest state (Today's rules).
    private var stressCaption: String {
        guard let today = todayVitals else { return "No values" }
        if let latest = today.latestStress { return Format.stressBand(latest) }
        if today.stressState == .exertion { return "Exertion" }
        if today.stressState == .hrOnly { return "HR only" }
        if today.calibration.days.isEmpty { return "No baseline" }
        if !today.calibration.isCalibrated {
            return "Calibrating \(today.calibration.qualifyingDays)/\(today.calibration.requiredDays)"
        }
        return "No values"
    }

    private var stressCaptionTint: Color? {
        guard let today = todayVitals else { return nil }
        if today.latestStress == nil, today.stressState == .exertion || today.stressState == .hrOnly {
            return Palette.warn
        }
        if today.latestStress == nil, !today.calibration.days.isEmpty, !today.calibration.isCalibrated {
            return Palette.warn
        }
        return nil
    }

    private func stressBandSegments(_ today: HealthTodaySnapshot) -> [MinuteStrip.Segment] {
        today.stressDay.bandMinutes
            .filter { $0.minutes > 0 }
            .enumerated()
            .map { index, entry in
                MinuteStrip.Segment(id: index, minutes: entry.minutes, color: Palette.stress(entry.band))
            }
    }

    private func stressBandAccessibility(_ today: HealthTodaySnapshot) -> String {
        today.stressDay.bandMinutes
            .filter { $0.minutes > 0 }
            .map { "\(Format.bandName($0.band)): \(Format.minutes($0.minutes))" }
            .joined(separator: ", ")
    }

    private func stressSummary(_ day: StressDaySummary) -> String {
        var parts: [String] = []
        if let average = day.average {
            parts.append("Avg \(Int(average.rounded()))")
        }
        if let peak = day.peak {
            parts.append("Peak \(peak)")
        }
        return parts.joined(separator: " · ")
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
