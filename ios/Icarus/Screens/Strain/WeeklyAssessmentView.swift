import Metrics
import SwiftUI

/// Last week against the week before: one row per metric with both averages and the change, then up to three
/// observations. Numbers come first in each sentence. Our wording and thresholds: see `WeeklyAssessment`.
struct WeeklyAssessmentView: View {
    let environment: AppEnvironment

    @State private var report: WeeklyAssessment.Report?

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.s16) {
                tableCard
                observationsCard
            }
            .pagePadding()
            .padding(.vertical, Spacing.s8)
        }
        .dashboardBackground()
        .navigationTitle("Weekly assessment")
        .task {
            let clock = environment.clock
            do {
                for try await value in environment.database.observe({ try CoachingModel.loadWeek($0, nowMs: clock.nowMs) }) {
                    report = value
                }
            } catch {
                report = nil
            }
        }
    }

    private var tableCard: some View {
        DashboardCard(title: "Last 7 days", symbol: "calendar", tint: Palette.strain) {
            Grid(alignment: .leading, horizontalSpacing: Spacing.s16, verticalSpacing: Spacing.s12) {
                GridRow {
                    Text("")
                    Text("This week")
                    Text("Before")
                    Text("Change")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                ForEach(rows, id: \.metric) { row in
                    GridRow {
                        Text(row.metric.title)
                            .font(.subheadline)
                        Text(valueText(row.thisWeek, row.metric))
                            .gridColumnAlignment(.trailing)
                        Text(valueText(row.previousWeek, row.metric))
                            .gridColumnAlignment(.trailing)
                        Text(deltaText(row))
                            .foregroundStyle(deltaColor(row))
                            .gridColumnAlignment(.trailing)
                    }
                    .font(.subheadline)
                    .monospacedDigit()
                }
            }
            Text("Averages need \(WeeklyAssessment.minimumDays) days. Recovery and sleep are estimates.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var observationsCard: some View {
        DashboardCard(title: "Observations", symbol: "text.quote", tint: Palette.neutral) {
            if let observations = report?.observations, !observations.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.s8) {
                    ForEach(observations, id: \.self) { line in
                        Text(line)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Text(report == nil ? "No data yet" : "No measure moved past its usual range this week.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Values

    private var rows: [WeeklyAssessment.Row] {
        report?.rows ?? WeeklyAssessment.Metric.allCases.map {
            WeeklyAssessment.Row(metric: $0, thisWeek: nil, previousWeek: nil, delta: nil)
        }
    }

    private func valueText(_ value: Double?, _ metric: WeeklyAssessment.Metric) -> String {
        guard let value else { return "--" }
        return withUnit(decimals: usesDecimals(metric), value, metric.unit)
    }

    private func deltaText(_ row: WeeklyAssessment.Row) -> String {
        guard let delta = row.delta else { return "--" }
        let sign = delta >= 0 ? "+" : "−"
        return sign + withUnit(decimals: usesDecimals(row.metric), abs(delta), row.metric.unit)
    }

    /// Green for an improvement and orange for a decline, where the metric has a direction. Colour carries
    /// meaning only here; the words carry the rest.
    private func deltaColor(_ row: WeeklyAssessment.Row) -> Color {
        guard let delta = row.delta, abs(delta) >= row.metric.threshold, let higherIsBetter = row.metric.higherIsBetter else {
            return .secondary
        }
        let improved = higherIsBetter ? delta > 0 : delta < 0
        return improved ? Palette.syncOK : Palette.warn
    }

    private func usesDecimals(_ metric: WeeklyAssessment.Metric) -> Bool {
        metric == .hoursSlept || metric == .strain
    }

    private func withUnit(decimals: Bool, _ value: Double, _ unit: String) -> String {
        let number = decimals ? String(format: "%.1f", value) : "\(Int(value.rounded()))"
        return unit.isEmpty ? number : "\(number) \(unit)"
    }
}
