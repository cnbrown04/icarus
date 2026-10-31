import Metrics
import Store
import SwiftUI

/// Medication profiles (Settings > Medications). Lists every profile with its schedule and effect window, and adds
/// one from a preset or as a custom entry. Tapping a row edits it; swipe deletes after a confirmation naming it.
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
        _model = State(initialValue: MedicationsModel(database: environment.database, clock: environment.clock))
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
                            MedicationListRow(profile: profile, timeZone: model.timeZone)
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
                } footer: {
                    Text("Onset and duration are typical label figures, not measured for you. Effects are approximate "
                        + "and not medical advice.")
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
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add medication")
                .accessibilityIdentifier("medications.add")
            }
        }
        .confirmationDialog("Add medication", isPresented: $showingPresets, titleVisibility: .visible) {
            // Each preset asks which schedule it takes: daily at 08:00 (editable), or as needed (no schedule).
            ForEach(MedicationProfile.Preset.allCases, id: \.self) { preset in
                Button("\(preset.name), daily at 08:00") {
                    editor = .new(preset.profile(id: model.newID(), scheduleMinutesOfDay: [8 * 60]))
                }
                Button("\(preset.name), as needed") {
                    editor = .new(preset.profile(id: model.newID(), scheduleMinutesOfDay: []))
                }
            }
            Button("Custom") {
                editor = .new(MedicationProfile(
                    id: model.newID(),
                    name: "",
                    medClass: .other,
                    formulation: .immediateRelease,
                    onsetMinutes: 30,
                    durationMinutes: 240,
                    scheduleMinutesOfDay: [8 * 60]
                ))
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
        } message: {
            Text("Its scheduled and logged doses stop showing and stop shading charts. The log is kept.")
        }
        .task {
            await model.load()
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No medications", systemImage: "pills")
        } actions: {
            Button("Add medication") {
                showingPresets = true
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("medications.empty.add")
        }
    }
}

/// One profile: name, class and formulation, then the schedule and its days.
private struct MedicationListRow: View {
    let profile: MedicationProfile
    let timeZone: TimeZone

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
        guard !profile.scheduleMinutesOfDay.isEmpty else {
            return "\(kind), \(formulation), as needed"
        }
        let times = profile.scheduleMinutesOfDay.map { MedicationFormat.clock(minuteOfDay: $0) }.joined(separator: ", ")
        return "\(kind), \(formulation), \(times), \(MedicationFormat.days(profile.weekdays))"
    }
}

/// Shared text for medication rows and the editor.
enum MedicationFormat {
    static func clock(minuteOfDay minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }

    /// "every day" for an empty set, else the short day names in calendar order.
    static func days(_ weekdays: Set<Int>) -> String {
        guard !weekdays.isEmpty else { return "every day" }
        return weekdays.sorted().map { Weekdays.veryShortName($0) }.joined(separator: " ")
    }
}
