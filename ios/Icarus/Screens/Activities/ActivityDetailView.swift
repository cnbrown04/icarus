import Charts
import Metrics
import Store
import SwiftUI

/// One workout: strain and duration, average, maximum heart rate and calories, the heart-rate chart over its span,
/// and zone time. Edit the kind and name, or delete it after confirmation. Entry view for a workout
/// (`environment`, `activityID`).
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
        List {
            if let detail {
                content(detail)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(row?.displayName ?? "Workout")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") {
                    editing = true
                }
                .disabled(row == nil)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Delete", role: .destructive) {
                    confirmDelete = true
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
            "Delete \(row?.displayName ?? "workout")?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
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
        Section {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: Spacing.s4) {
                    Text(ActivitiesModel.strainText(row.strain))
                        .font(.figureLarge)
                        .monospacedDigit()
                    Text("Strain")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: Spacing.s8)
                VStack(alignment: .trailing, spacing: Spacing.s4) {
                    Text(Format.duration((row.endMs - row.startMs) / 1000))
                        .font(.figure)
                        .monospacedDigit()
                    Text("Duration")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, Spacing.s4)
            .accessibilityElement(children: .combine)
        }

        Section {
            LabeledContent("Average Heart Rate") {
                Text(ActivitiesModel.bpmText(row.avgHR))
            }
            LabeledContent("Max Heart Rate") {
                Text(ActivitiesModel.bpmText(row.maxHR.map(Double.init)))
            }
            LabeledContent("Calories") {
                Text(ActivitiesModel.kcalText(row.kcal))
            }
        }

        Section("Heart Rate") {
            if detail.points.isEmpty {
                EmptyStateRow(text: "No heart rate in this span", actionTitle: nil, action: nil)
            } else {
                readout(detail)
                chart(detail)
            }
        }

        if row.zoneTotals.contains(where: { $0.minutes > 0 }) {
            Section("Zones") {
                ZoneBar(zones: row.zoneTotals)
                    .padding(.vertical, Spacing.s4)
            }
        }
    }

    /// The value under the chart: the selected reading and its time, or the workout's average when nothing is selected.
    private func readout(_ detail: ActivitiesModel.Detail) -> some View {
        let selected = selectedPoint(in: detail.points)
        let value = selected?.bpm ?? detail.row.avgHR
        return HStack(alignment: .firstTextBaseline, spacing: Spacing.s4) {
            Text(value.map { Int($0.rounded()).formatted() } ?? "—")
                .font(.figure)
                .monospacedDigit()
            if value != nil {
                Text("bpm")
                    .font(.figureUnit)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Spacing.s8)
            if let selected {
                Text(Format.clock(Int64(selected.date.timeIntervalSince1970 * 1000), in: detail.timeZone))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("Average")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func chart(_ detail: ActivitiesModel.Detail) -> some View {
        let selected = selectedPoint(in: detail.points)
        let average = detail.row.avgHR
        return Chart {
            ForEach(detail.points) { point in
                LineMark(x: .value("Time", point.date), y: .value("Heart Rate", point.bpm))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(MetricCategory.activity.color)
            }
            if let average {
                RuleMark(y: .value("Average", average))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            if let selected {
                RuleMark(x: .value("Selected", selected.date))
                    .foregroundStyle(.secondary)
                PointMark(x: .value("Selected", selected.date), y: .value("Heart Rate", selected.bpm))
                    .foregroundStyle(MetricCategory.activity.color)
            }
        }
        .chartYScale(domain: ChartDomain.line(detail.points.map(\.bpm)))
        .chartXSelection(value: $selection)
        .metricChartStyle()
        .frame(height: ChartHeight.detail)
        .accessibilityLabel("Heart rate during \(detail.row.displayName)")
    }

    private func selectedPoint(in points: [HRPoint]) -> HRPoint? {
        guard let selection else { return nil }
        return points.min { lhs, rhs in
            abs(lhs.date.timeIntervalSince(selection)) < abs(rhs.date.timeIntervalSince(selection))
        }
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

/// Kind and name for one workout. Saving makes an auto-detected row manual, so detection leaves it alone.
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
        .navigationTitle("Edit Workout")
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
