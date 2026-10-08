import Metrics
import Store
import SwiftUI

/// Today's resting and active calories, by hour, a week of totals, and the inputs used (PLAN.md §14 row 10).
struct CaloriesDetailView: View {
    let environment: AppEnvironment

    @State private var snapshot: Dashboard.CaloriesSnapshot?

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.s16) {
                DashboardCard(title: "Today", symbol: "flame.fill", tint: .orange) {
                    HStack(spacing: Spacing.s24) {
                        RingProgress(fraction: activeShare, summary: "Active share of today's calories") {
                            VStack(spacing: Spacing.s4) {
                                Text(totalText)
                                    .font(.metricValue)
                                    .monospacedDigit()
                                    .contentTransition(.numericText())
                                Text("total")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: Spacing.s48 * 3, height: Spacing.s48 * 3)
                        VStack(alignment: .leading, spacing: Spacing.s12) {
                            breakdownRow(title: "Active", value: activeText, tint: Palette.caloriesActive)
                            breakdownRow(title: "Resting", value: restingText, tint: Palette.caloriesResting)
                        }
                    }
                    Text("Estimated")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ChartCard(title: "By hour") {
                    EmptyView()
                } chart: {
                    if hasHourlyData {
                        HourlyCaloriesChart(hours: snapshot?.hours ?? [])
                            .frame(height: Spacing.s48 * 3)
                    } else {
                        Text("No calories yet today")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                ChartCard(title: "Seven days") {
                    Text(weekAverage)
                        .font(.metricValue)
                        .monospacedDigit()
                } chart: {
                    DayBarChart(
                        points: weekTotals.points,
                        color: { _ in Palette.caloriesActive },
                        average: weekTotals.average
                    )
                    .frame(height: Spacing.s48 * 3)
                    .accessibilityLabel("Calories, seven days")
                }

                DashboardCard(title: "Inputs", symbol: "list.bullet", tint: .secondary) {
                    VStack(alignment: .leading, spacing: Spacing.s8) {
                        ForEach(Array(inputRows.enumerated()), id: \.offset) { _, row in
                            HStack {
                                Text(row.label)
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: Spacing.s8)
                                Text(row.value)
                                    .monospacedDigit()
                            }
                            .font(.subheadline)
                        }
                    }
                    if snapshot?.context.profile == nil {
                        Text("Set a profile to estimate calories.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .pagePadding()
            .padding(.vertical, Spacing.s8)
        }
        .dashboardBackground()
        .navigationTitle("Calories")
        .task {
            for await value in environment.snapshots(every: .seconds(15), { db, nowMs in
                try Dashboard.calories(db, nowMs: nowMs)
            }) {
                snapshot = value
            }
        }
    }

    private func breakdownRow(title: String, value: String, tint: Color) -> some View {
        HStack(spacing: Spacing.s8) {
            Circle()
                .fill(tint)
                .frame(width: Spacing.s8, height: Spacing.s8)
            VStack(alignment: .leading) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
        }
    }

    private var hasHourlyData: Bool {
        snapshot?.hours.contains(where: { $0.resting + $0.active > 0 }) ?? false
    }

    private var totalText: String {
        snapshot?.total.map { Format.number($0, unit: "") } ?? "--"
    }

    private var activeText: String {
        snapshot?.active.map { Format.kcal($0) } ?? "--"
    }

    private var restingText: String {
        guard let total = snapshot?.total, let active = snapshot?.active else { return "--" }
        return Format.kcal(total - active)
    }

    private var activeShare: Double {
        guard let total = snapshot?.total, total > 0, let active = snapshot?.active else { return 0 }
        return active / total
    }

    private var weekTotals: TrendSeries {
        TrendSeries.make(
            days: snapshot?.week ?? [],
            timeZone: snapshot?.context.timeZone ?? Dashboard.fallbackZone,
            value: \.kcalTotal,
            currentCount: 7
        )
    }

    private var weekAverage: String {
        weekTotals.average.map { Format.kcal($0) } ?? "--"
    }

    private struct InputRow {
        let label: String
        let value: String
    }

    private var inputRows: [InputRow] {
        guard let context = snapshot?.context else { return [] }
        var rows: [InputRow] = []
        if let profile = context.profile {
            rows.append(InputRow(label: "Formula sex", value: profile.formula.map(Self.sexLabel) ?? "Not set"))
            let year = LocalTime.localDay(containing: context.nowMs, in: context.timeZone).year
            rows.append(InputRow(
                label: "Age",
                value: profile.birthYear.map { "\(max(0, year - $0)) years" } ?? "Not set"
            ))
            rows.append(InputRow(label: "Height", value: profile.heightCm.map { "\(Int($0.rounded())) cm" } ?? "Not set"))
            rows.append(InputRow(label: "Weight", value: profile.weightKg.map { "\(Int($0.rounded())) kg" } ?? "Not set"))
        }
        rows.append(InputRow(label: "HRmax", value: context.maxHR.map { Format.bpm($0) } ?? "Not set"))
        rows.append(InputRow(label: "Resting HR, last night", value: context.restingHR.map { Format.bpm($0) } ?? "--"))
        return rows
    }

    private static func sexLabel(_ sex: FormulaSex) -> String {
        switch sex {
        case .male: "Male"
        case .female: "Female"
        }
    }
}
