import Charts
import Metrics
import Store
import SwiftUI

/// Today's resting and active calories, by hour, with the inputs used (PLAN.md §14 row 10).
struct CaloriesDetailView: View {
    let environment: AppEnvironment

    @State private var snapshot: Dashboard.CaloriesSnapshot?

    var body: some View {
        List {
            Section {
                LabeledContent("Total", value: snapshot?.total.map { Format.kcal($0) } ?? "--")
                    .monospacedDigit()
                LabeledContent("Active", value: snapshot?.active.map { Format.kcal($0) } ?? "--")
                    .monospacedDigit()
            } footer: {
                Text("Estimated")
            }

            Section("By hour") {
                chart
                    .frame(height: Spacing.s48 * 3)
            }

            Section {
                ForEach(inputRows, id: \.label) { row in
                    LabeledContent(row.label, value: row.value)
                        .monospacedDigit()
                }
            } header: {
                Text("Inputs")
            } footer: {
                if snapshot?.context.profile == nil {
                    Text("Set a profile to estimate calories.")
                }
            }
        }
        .navigationTitle("Calories")
        .task {
            for await value in environment.snapshots(every: .seconds(15), { db, nowMs in
                try Dashboard.calories(db, nowMs: nowMs)
            }) {
                snapshot = value
            }
        }
    }

    @ViewBuilder
    private var chart: some View {
        if let hours = snapshot?.hours, hours.contains(where: { $0.resting + $0.active > 0 }) {
            Chart(hours) { hour in
                BarMark(
                    x: .value("Hour", hour.id),
                    y: .value("kcal", hour.resting)
                )
                .foregroundStyle(by: .value("Type", "Resting"))
                BarMark(
                    x: .value("Hour", hour.id),
                    y: .value("kcal", hour.active)
                )
                .foregroundStyle(by: .value("Type", "Active"))
            }
            .accessibilityLabel("Calories by hour, today")
        } else {
            Text("No calories yet today")
                .foregroundStyle(.secondary)
        }
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
