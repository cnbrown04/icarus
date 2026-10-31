import Metrics
import Store
import SwiftUI

/// Creates or edits one medication profile: name, class, formulation, onset, duration, dose times, repeat days and
/// active state. An existing profile also has its doses: skip a scheduled day, or log an as-needed dose, and the last
/// seven days with remove. Delete is at the bottom of an existing profile and asks first.
struct MedicationEditorView: View {
    let model: MedicationsModel
    let isNew: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var draft: MedicationProfile
    @State private var confirmingDelete = false
    @State private var saving = false
    @State private var skipping = false
    @State private var logging = false

    init(model: MedicationsModel, initial: MedicationProfile, isNew: Bool) {
        self.model = model
        self.isNew = isNew
        _draft = State(initialValue: initial)
    }

    private var trimmedName: String {
        draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Medication") {
                    TextField("Name", text: $draft.name)
                        .accessibilityIdentifier("medication.name")
                    Picker("Class", selection: $draft.medClass) {
                        Text("Stimulant").tag(MedicationClass.stimulant)
                        Text("Other").tag(MedicationClass.other)
                    }
                    Picker("Formulation", selection: $draft.formulation) {
                        Text("Immediate release").tag(MedicationFormulation.immediateRelease)
                        Text("Extended release").tag(MedicationFormulation.extendedRelease)
                    }
                }

                Section {
                    Stepper(value: $draft.onsetMinutes, in: 0...720, step: 5) {
                        LabeledContent("Onset") {
                            Text(Format.duration(minutes: draft.onsetMinutes)).monospacedDigit()
                        }
                    }
                    Stepper(value: $draft.durationMinutes, in: 15...1440, step: 15) {
                        LabeledContent("Duration") {
                            Text(Format.duration(minutes: draft.durationMinutes)).monospacedDigit()
                        }
                    }
                } header: {
                    Text("Effect")
                } footer: {
                    Text("Typical label figures, not measured for you.")
                }

                Section {
                    Picker("Schedule", selection: scheduleKind) {
                        Text("Daily at").tag(ScheduleKind.daily)
                        Text("As needed").tag(ScheduleKind.asNeeded)
                    }
                    .pickerStyle(.segmented)
                    if scheduleKind.wrappedValue == .daily {
                        ForEach(draft.scheduleMinutesOfDay.indices, id: \.self) { index in
                            DatePicker(
                                "Dose",
                                selection: timeBinding(index),
                                displayedComponents: .hourAndMinute
                            )
                        }
                        .onDelete { offsets in
                            draft.scheduleMinutesOfDay.remove(atOffsets: offsets)
                        }
                        Button("Add time") {
                            draft.scheduleMinutesOfDay.append(draft.scheduleMinutesOfDay.last ?? MedicationFormat.defaultDoseMinute)
                        }
                    }
                } header: {
                    Text("Schedule")
                } footer: {
                    Text(scheduleKind.wrappedValue == .daily
                        ? "Scheduled doses are assumed taken unless skipped."
                        : "No schedule. Log each dose under Last \(MedicationsModel.logWindowDays) days.")
                }

                if scheduleKind.wrappedValue == .daily {
                    Section {
                        WeekdayChips(selection: $draft.weekdays, tint: Palette.strain)
                    } header: {
                        Text("Repeat")
                    } footer: {
                        Text("No days selected means every day.")
                    }
                }

                if !isNew {
                    Section {
                        if draft.scheduleMinutesOfDay.isEmpty {
                            Button("Log a dose…") {
                                logging = true
                            }
                            .accessibilityIdentifier("medication.logDose")
                        } else {
                            Button("Skip a day…") {
                                skipping = true
                            }
                            .accessibilityIdentifier("medication.skipDay")
                        }
                        let entries = model.recentDoses[draft.id] ?? []
                        if entries.isEmpty {
                            EmptyStateRow(
                                text: "Nothing logged in the last \(MedicationsModel.logWindowDays) days",
                                actionTitle: nil,
                                action: nil
                            )
                        } else {
                            ForEach(entries) { entry in
                                doseRow(entry)
                            }
                        }
                    } header: {
                        Text("Last \(MedicationsModel.logWindowDays) days")
                    }
                }

                Section {
                    Toggle("Active", isOn: $draft.active)
                } footer: {
                    Text("Inactive medications add no doses or stress shading.")
                }

                if !isNew {
                    Section {
                        Button("Delete medication", role: .destructive) {
                            confirmingDelete = true
                        }
                        .accessibilityIdentifier("medication.delete")
                    }
                }
            }
            .sheet(isPresented: $skipping) {
                SkipDaySheet(model: model, medicationID: draft.id)
            }
            .sheet(isPresented: $logging) {
                LogDoseSheet(model: model, medicationID: draft.id)
            }
            .navigationTitle(isNew ? "New medication" : (trimmedName.isEmpty ? "Medication" : trimmedName))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        Task {
                            var profile = draft
                            profile.name = trimmedName
                            await model.save(profile)
                            saving = false
                            dismiss()
                        }
                    }
                    .disabled(trimmedName.isEmpty || saving)
                    .accessibilityIdentifier("medication.save")
                }
            }
            .confirmationDialog(
                "Delete \(trimmedName.isEmpty ? "medication" : trimmedName)?",
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    Task {
                        await model.delete(draft.id)
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Its scheduled and logged doses stop showing and stop shading charts. The log is kept.")
            }
        }
    }

    /// One logged dose or skip, with remove.
    private func doseRow(_ entry: DoseOverrideEntry) -> some View {
        let text = doseText(entry)
        return HStack {
            Text(text)
                .font(.subheadline)
            Spacer()
            Button {
                Task { await model.removeDose(entry.id) }
            } label: {
                Image(systemName: "minus.circle")
                    .frame(minWidth: MinTouch.size, minHeight: MinTouch.size)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove " + text)
        }
    }

    private func doseText(_ entry: DoseOverrideEntry) -> String {
        let day = JournalFormat.dayTitle(entry.override.day, in: model.timeZone)
        guard let atMs = entry.override.takenMs else {
            return "\(day), skipped"
        }
        return "\(day), taken \(Format.clock(atMs, in: model.timeZone))"
    }

    /// Daily at specific times, or as needed. As needed is an empty schedule. Choosing Daily restores one default time.
    private enum ScheduleKind: Hashable {
        case daily
        case asNeeded
    }

    private var scheduleKind: Binding<ScheduleKind> {
        Binding(
            get: { draft.scheduleMinutesOfDay.isEmpty ? .asNeeded : .daily },
            set: { kind in
                switch kind {
                case .asNeeded:
                    draft.scheduleMinutesOfDay = []
                case .daily:
                    if draft.scheduleMinutesOfDay.isEmpty {
                        draft.scheduleMinutesOfDay = [MedicationFormat.defaultDoseMinute]
                    }
                }
            }
        )
    }

    /// The schedule stores minutes of the day. The picker works in a Date on the model's zone.
    private func timeBinding(_ index: Int) -> Binding<Date> {
        Binding(
            get: {
                let minute = draft.scheduleMinutesOfDay.indices.contains(index) ? draft.scheduleMinutesOfDay[index] : 0
                return dateFor(minute: minute)
            },
            set: { newValue in
                guard draft.scheduleMinutesOfDay.indices.contains(index) else { return }
                draft.scheduleMinutesOfDay[index] = minuteOfDay(newValue)
            }
        )
    }

    private func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = model.timeZone
        return calendar
    }

    private func dateFor(minute: Int) -> Date {
        let calendar = calendar()
        let start = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .minute, value: minute, to: start) ?? start
    }

    private func minuteOfDay(_ date: Date) -> Int {
        let parts = calendar().dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}

/// Skips the scheduled dose on one chosen day. Writes a skip that replaces anything logged that day.
private struct SkipDaySheet: View {
    let model: MedicationsModel
    let medicationID: String

    @Environment(\.dismiss) private var dismiss
    @State private var day = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Day", selection: $day, displayedComponents: .date)
                        .accessibilityIdentifier("medication.skipDate")
                } footer: {
                    Text("The scheduled dose on that day is not counted as taken.")
                }
            }
            .navigationTitle("Skip a day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Skip") {
                        Task {
                            await model.skipDay(medicationID, on: MedicationsModel.deviceDay(day))
                            dismiss()
                        }
                    }
                    .accessibilityIdentifier("medication.skipConfirm")
                }
            }
        }
    }
}

/// Logs one as-needed dose. The day defaults to today and the time to now. Other doses that day are kept.
private struct LogDoseSheet: View {
    let model: MedicationsModel
    let medicationID: String

    @Environment(\.dismiss) private var dismiss
    @State private var day = Date()
    @State private var time = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Day", selection: $day, displayedComponents: .date)
                        .accessibilityIdentifier("medication.logDate")
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                        .accessibilityIdentifier("medication.logTime")
                }
            }
            .navigationTitle("Log a dose")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Log") {
                        Task {
                            await model.logDose(medicationID, on: MedicationsModel.deviceDay(day), at: time)
                            dismiss()
                        }
                    }
                    .accessibilityIdentifier("medication.logConfirm")
                }
            }
        }
    }
}
