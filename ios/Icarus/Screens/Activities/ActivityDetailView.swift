import Metrics
import Store
import SwiftUI

/// One activity: strain, duration, heart rate, kcal, zone time and the heart-rate chart over its span. Edit the kind and
/// name, or delete it after confirmation. Entry view for the Activities stream (`environment`, `activityID`).
struct ActivityDetailView: View {
    let environment: AppEnvironment
    let activityID: String

    @Environment(\.dismiss) private var dismiss
    @State private var detail: ActivitiesModel.Detail?
    @State private var selection: Date?
    @State private var editing = false
    @State private var confirmDelete = false

    private var row: ActivityRow? {
        detail?.row
    }

    var body: some View {
        ScrollView {
            if let detail {
                content(detail)
            }
        }
        .dashboardBackground()
        .navigationTitle(row?.displayName ?? "Activity")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") {
                    editing = true
                }
                .disabled(row == nil)
            }
        }
        .sheet(isPresented: $editing) {
            if let row {
                NavigationStack {
                    ActivityEditView(environment: environment, row: row)
                }
            }
        }
        .confirmationDialog(
            "Delete \(row?.displayName ?? "activity")?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete activity", role: .destructive) {
                delete()
            }
        }
        .task {
            for await value in environment.snapshots(every: .seconds(60), { db, _ in
                try ActivitiesModel.detail(db, id: activityID)
            }) {
                detail = value
            }
        }
    }

    @ViewBuilder
    private func content(_ detail: ActivitiesModel.Detail) -> some View {
        let row = detail.row
        let duration = Format.duration((row.endMs - row.startMs) / 1000)
        let average = row.avgHR
        VStack(spacing: Spacing.s16) {
            Text(row.isAuto ? "Detected from heart rate" : "Recorded by you")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: Spacing.s12) {
                StatTile(title: "Strain", value: row.strain.map { "\(ActivitiesModel.strainText($0)) / 21" } ?? "--")
                StatTile(title: "Duration", value: duration)
            }
            HStack(spacing: Spacing.s12) {
                StatTile(title: "Average HR", value: average.map { Format.bpm($0) } ?? "--")
                StatTile(title: "Max HR", value: row.maxHR.map { Format.bpm($0) } ?? "--")
            }
            StatTile(title: "Calories", value: row.kcal.map { Format.kcal($0) } ?? "--")
            Text("Calories are estimated from heart rate.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            ChartCard(title: "Heart rate", footer: nil) {
                Text(average.map { "Average \(Format.bpm($0))" } ?? "No heart rate in this span")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } chart: {
                if detail.points.isEmpty {
                    Text("No heart rate in this span")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    HRAreaChart(points: detail.points, average: average, selection: $selection)
                        .frame(height: Spacing.s48 * 3)
                        .accessibilityLabel("Heart rate during \(row.displayName)")
                }
            }

            if row.zoneTotals.contains(where: { $0.minutes > 0 }) {
                DashboardCard(title: "Zones", symbol: "heart", tint: Palette.heartRate) {
                    ZoneBar(zones: row.zoneTotals)
                }
            }

            Button("Delete activity", role: .destructive) {
                confirmDelete = true
            }
            .frame(maxWidth: .infinity)
            .padding(.top, Spacing.s8)
        }
        .pagePadding()
        .padding(.vertical, Spacing.s8)
    }

    private func delete() {
        let id = activityID
        let nowMs = environment.clock.nowMs
        Task {
            _ = try? await environment.database.writer.write { db in
                try db.deleteActivity(id: id, computedAtMs: nowMs)
            }
            dismiss()
        }
    }
}

/// Kind and name for one activity. Saving makes an auto-detected row manual, so detection leaves it alone.
struct ActivityEditView: View {
    let environment: AppEnvironment
    let row: ActivityRow

    @Environment(\.dismiss) private var dismiss
    @State private var kind: ActivityKind
    @State private var name: String

    init(environment: AppEnvironment, row: ActivityRow) {
        self.environment = environment
        self.row = row
        _kind = State(initialValue: row.activityKind)
        _name = State(initialValue: row.name ?? "")
    }

    var body: some View {
        Form {
            Picker("Kind", selection: $kind) {
                ForEach(ActivityKind.allCases, id: \.self) { option in
                    Text(option.label).tag(option)
                }
            }
            TextField("Name", text: $name)
                .submitLabel(.done)
        }
        .navigationTitle("Edit activity")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    save()
                }
            }
        }
    }

    private func save() {
        let id = row.id
        let kind = kind
        let name = name
        let nowMs = environment.clock.nowMs
        Task {
            _ = try? await environment.database.writer.write { db in
                try db.updateActivity(id: id, kind: kind, name: name, computedAtMs: nowMs)
            }
            dismiss()
        }
    }
}
