import Charts
import Metrics
import Store
import SwiftUI

/// Recovery for one day: the score ring, the four contributors against their 30-night baselines, and the
/// last 30 days of scores. Calibrating shows the night count until the baseline is trusted (Home's rule).
struct RecoveryDetailView: View {
    let environment: AppEnvironment
    let liveState: LiveState
    let day: LocalDay

    @State private var snapshot: HealthSnapshot?

    /// Days of scores the bar chart shows, ending on `day`.
    private static let seriesDays = 30

    private var readout: RecoveryReadout {
        RecoveryReadout(outcome: snapshot?.scores.recovery)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.s24) {
                scoreCard
                contributorsCard
                trendCard
            }
            .pagePadding()
            .padding(.vertical, Spacing.s8)
            .redacted(reason: snapshot == nil ? .placeholder : [])
        }
        .dashboardBackground()
        .navigationTitle("Recovery")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await environment.sync.runNow()
        }
        .task {
            let day = day
            let seriesDays = Self.seriesDays
            for await value in environment.snapshots(every: .seconds(300), { db, nowMs in
                try HealthSnapshot.load(db, nowMs: nowMs, day: day, seriesDays: seriesDays)
            }) {
                snapshot = value
            }
        }
    }

    // MARK: Score

    private var scoreCard: some View {
        VStack(spacing: Spacing.s16) {
            Text(snapshot.map(\.dayLabel) ?? "")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            RingProgress(fraction: readout.fraction, summary: readout.summary, tint: readout.tint, lineWidth: Spacing.s16) {
                VStack(spacing: Spacing.s4) {
                    Text(readout.value)
                        .font(.heroValue)
                        .monospacedDigit()
                    if readout.hasScore {
                        Text("%")
                            .font(.metricUnit)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: Spacing.s48 * 3, height: Spacing.s48 * 3)
            .padding(.vertical, Spacing.s8)
            Text(readout.caption)
                .font(.subheadline)
                .foregroundStyle(readout.isCalibrating ? Palette.warn : .secondary)
            Text("Estimated from your own baseline. Not WHOOP's score.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.s16)
        .cardBackground()
    }

    // MARK: Contributors

    private var contributorsCard: some View {
        DashboardCard(title: "Contributors", symbol: "list.bullet", tint: Palette.hrv) {
            VStack(alignment: .leading, spacing: Spacing.s16) {
                vitalRow(.hrv)
                vitalRow(.restingHR)
                vitalRow(.respiratoryRate)
                sleepPerformanceRow
                if snapshot?.scores.stimulantNearSleepOnset == true {
                    Text("Stimulant active within 1 h of sleep onset")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// One vital: tonight, the 30-night reference it is judged against, and the difference.
    private func vitalRow(_ vital: HealthMonitor.Vital) -> some View {
        let tonight = snapshot?.vitals.tonight[vital]
        let reference = snapshot?.vitals.baselines[vital]?.center
        return ContributorRow(
            title: vital.title,
            tonight: tonight.map(vital.text) ?? "—",
            baseline: reference.map { "30-night \(vital.text($0))" },
            delta: difference(tonight, reference),
            deltaUnit: vital.unit
        )
    }

    /// Sleep performance has no personal range in `HealthMonitor`, so its reference is the median of the
    /// prior days in the chart window (needs `HealthMonitor.minimumNights` of them).
    private var sleepPerformanceRow: some View {
        let tonight = snapshot?.scores.sleep?.performancePct
        let prior = (snapshot?.series ?? []).filter { $0.day != day }.compactMap(\.sleepPerformance)
        let reference = prior.count >= HealthMonitor.minimumNights ? HealthMonitor.median(prior) : nil
        return ContributorRow(
            title: "Sleep performance",
            tonight: tonight.map { "\(Int($0.rounded())) %" } ?? "—",
            baseline: reference.map { "\(Int($0.rounded())) % over \(prior.count) days" },
            delta: difference(tonight, reference),
            deltaUnit: "%"
        )
    }

    private func difference(_ value: Double?, _ reference: Double?) -> Double? {
        guard let value, let reference else { return nil }
        return value - reference
    }

    // MARK: Trend

    private var trendCard: some View {
        ChartCard(title: "Last 30 days", footer: "Days without a scored night are left out.") {
            EmptyView()
        } chart: {
            recoveryBars
                .frame(height: Spacing.s48 * 3)
        }
    }

    private var recoveryBars: some View {
        let points = (snapshot?.series ?? []).compactMap { point -> (date: Date, value: Double)? in
            guard let value = point.recovery, let snapshot else { return nil }
            return (Date(epochMs: LocalTime.localTime(point.day, hour: 12, in: snapshot.timeZone)), value)
        }
        return Chart(points, id: \.date) { point in
            BarMark(x: .value("Day", point.date, unit: .day), y: .value("Recovery", point.value))
                .foregroundStyle(Palette.recovery(Recovery.band(for: point.value)))
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100])
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    .font(.caption2.monospacedDigit())
            }
        }
        .accessibilityLabel("Recovery, last 30 days")
    }
}

/// A contributor: the name, tonight's value, its reference and a change chip against it.
private struct ContributorRow: View {
    let title: String
    let tonight: String
    let baseline: String?
    let delta: Double?
    let deltaUnit: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s8) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s8) {
                Text(tonight)
                    .font(.metricValue)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer(minLength: Spacing.s8)
                if let delta {
                    DeltaChip(change: delta, unit: deltaUnit)
                }
            }
            if let baseline {
                Text(baseline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
