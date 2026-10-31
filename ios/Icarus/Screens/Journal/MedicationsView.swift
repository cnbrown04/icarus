import Metrics
import Store
import SwiftUI

/// Medications: a set-once calculation setting, not a daily tracker. Used to compare stress during medicated hours
/// against the medicated baseline. Lists each profile with its schedule, and adds one from a preset or as a custom
/// entry. Tapping a row opens its detail, where doses are skipped or logged. Swipe deletes after a confirmation.
struct MedicationsView: View {
    let environment: AppEnvironment

    @State private var model: MedicationsModel
    @State private var editor: EditorTarget?
    @State private var showingPresets = false
    @State private var pendingDelete: MedicationProfile?

    /// What the editor sheet opens on: a new profile, or a saved one.
    private enum EditorTarget: Identifiable {
        case new(MedicationProfile)
        case edit(MedicationProfile)

        var id: String {
            switch self {
            case let .new(profile), let .edit(profile): profile.id
            }
        }

        var profile: MedicationProfile {
            switch self {
            case let .new(profile), let .edit(profile): profile
            }
        }

        var isNew: Bool {
            if case .new = self { true } else { false }
        }
    }

    init(environment: AppEnvironment) {
        self.environment = environment
        _model = State(initialValue: MedicationsModel(database: environment.database, clock: environment.clock,
                                                           recomputeStale: environment.recomputeStaleMetrics))
    }

    private func startNew(_ preset: MedicationProfile.Preset, schedule: [Int]) {
        let profile: MedicationProfile = preset.profile(id: model.newID(), scheduleMinutesOfDay: schedule)
        editor = .new(profile)
    }

    private func startCustom() {
        let profile = MedicationProfile(
            id: model.newID(),
            name: "",
            medClass: .other,
            formulation: .immediateRelease,
            onsetMinutes: 30,
            durationMinutes: 240,
            scheduleMinutesOfDay: [MedicationFormat.defaultDoseMinute]
        )
        editor = .new(profile)
    }

    var body: some View {
        List {
            if model.profiles.isEmpty {
                Section {
                    emptyState
                }
            } else {
                Section {
                    ForEach(model.profiles) { profile in
                        Button {
                            editor = .edit(profile)
                        } label: {
                            MedicationListRow(profile: profile)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                pendingDelete = profile
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }

            if let message = model.errorMessage {
                Section {
                    Text(message).foregroundStyle(Palette.error)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Medications")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingPresets = true
                } label: {
                    Image(systemName: Symbol.record)
                }
                .accessibilityLabel("Add medication")
                .accessibilityIdentifier("medications.add")
            }
        }
        .confirmationDialog("Add medication", isPresented: $showingPresets, titleVisibility: .visible) {
            // Each preset asks which schedule it takes: daily at 08:00 (editable), or as needed (no schedule).
            ForEach(MedicationProfile.Preset.allCases, id: \.self) { preset in
                Button("\(preset.name), daily at \(MedicationFormat.clock(minuteOfDay: MedicationFormat.defaultDoseMinute))") {
                    startNew(preset, schedule: [MedicationFormat.defaultDoseMinute])
                }
                Button("\(preset.name), as needed") {
                    startNew(preset, schedule: [])
                }
            }
            Button("Custom") {
                startCustom()
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $editor) { target in
            MedicationEditorView(model: model, initial: target.profile, isNew: target.isNew)
        }
        .confirmationDialog(
            "Delete \(pendingDelete?.name ?? "medication")?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let profile = pendingDelete {
                    Task { await model.delete(profile.id) }
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        }
        .task {
            await model.load()
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No medications", systemImage: Symbol.medications)
        } actions: {
            Button("Add medication") {
                showingPresets = true
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("medications.empty.add")
        }
    }
}

/// One profile: name, then its schedule summary and class and formulation.
private struct MedicationListRow: View {
    let profile: MedicationProfile

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s4) {
            HStack {
                Text(profile.name)
                if !profile.active {
                    Text("Inactive")
                        .font(.caption)
                        .foregroundStyle(Palette.neutral)
                }
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(Palette.neutral)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        let kind = profile.medClass == .stimulant ? "Stimulant" : "Other"
        let formulation = profile.formulation == .extendedRelease ? "extended release" : "immediate release"
        let schedule = MedicationFormat.schedule(times: profile.scheduleMinutesOfDay, weekdays: profile.weekdays)
        return "\(schedule) · \(kind), \(formulation)"
    }
}

/// Shared text for medication rows and the detail screen.
enum MedicationFormat {
    /// The default dose time for a new scheduled profile: 08:00, as minutes of the day.
    static let defaultDoseMinute = 8 * 60

    /// A minute of the day as a locale-aware clock time, e.g. "8:00 AM".
    static func clock(minuteOfDay minute: Int) -> String {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let date = calendar.date(byAdding: .minute, value: minute, to: start) ?? start
        return date.formatted(date: .omitted, time: .shortened)
    }

    /// "Daily 9:00", "Mon, Wed 9:00, 17:00", or "As needed" for an empty schedule.
    static func schedule(times: [Int], weekdays: Set<Int>) -> String {
        guard !times.isEmpty else { return "As needed" }
        let days = weekdays.isEmpty ? "Daily" : weekdays.sorted().map { Weekdays.shortName($0) }.joined(separator: ", ")
        let clocks = times.map { clock(minuteOfDay: $0) }.joined(separator: ", ")
        return "\(days) \(clocks)"
    }
}
