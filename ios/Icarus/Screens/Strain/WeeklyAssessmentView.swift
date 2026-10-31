import Metrics
import SwiftUI

/// Last 7 days against the 7 before: one row per metric with this week's average and the change, then the
/// observations as plain rows. Our wording and thresholds live in `WeeklyAssessment`.
struct WeeklyAssessmentView: View {
    let environment: AppEnvironment

    @State private var report: WeeklyAssessment.Report?

    var body: some View {
        List {
            if hasAnyAverage {
                Section("Last 7 days") {
                    ForEach(rows, id: \.metric) { row in
                        HStack(spacing: Spacing.s12) {
                            Text(row.metric.title)
                            Spacer(minLength: Spacing.s8)
                            Text(valueText(row.thisWeek, row.metric))
                                .monospacedDigit()
                            Text(deltaText(row))
                                .monospacedDigit()
                                .foregroundStyle(deltaColor(row))
                                .frame(minWidth: Spacing.s48, alignment: .trailing)
                        }
                    }
                }
            } else if report != nil {
                Section {
                    EmptyStateRow(text: "Not enough data for a week yet", actionTitle: nil, action: nil)
                }
            }
            if let observations = report?.observations, !observations.isEmpty {
                Section("Observations") {
                    ForEach(observations, id: \.self) { line in
                        Text(line)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Weekly assessment")
        .navigationBarTitleDisplayMode(.inline)
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

    // MARK: Values

    private var rows: [WeeklyAssessment.Row] {
        report?.rows ?? WeeklyAssessment.Metric.allCases.map {
            WeeklyAssessment.Row(metric: $0, thisWeek: nil, previousWeek: nil, delta: nil)
        }
    }

    /// True once a week has enough days for at least one average. Below that the table is replaced by one line.
    private var hasAnyAverage: Bool {
        rows.contains { $0.thisWeek != nil }
    }

    private func valueText(_ value: Double?, _ metric: WeeklyAssessment.Metric) -> String {
        guard let value else { return "—" }
        return withUnit(number(value, metric), metric.unit)
    }

    private func deltaText(_ row: WeeklyAssessment.Row) -> String {
        guard let delta = row.delta else { return "—" }
        let sign = delta >= 0 ? "+" : "−"
        return sign + withUnit(number(abs(delta), row.metric), row.metric.unit)
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

    /// One decimal for hours and strain, whole numbers otherwise.
    private func number(_ value: Double, _ metric: WeeklyAssessment.Metric) -> String {
        let decimals = metric == .hoursSlept || metric == .strain ? 1 : 0
        return value.formatted(.number.precision(.fractionLength(decimals)))
    }

    /// "47%" has no space before the percent sign; "65 bpm" and "6.4 h" do.
    private func withUnit(_ number: String, _ unit: String) -> String {
        if unit.isEmpty { return number }
        return unit == "%" ? number + unit : "\(number) \(unit)"
    }
}
