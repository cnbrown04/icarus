import Metrics
import SwiftUI

/// Creates or edits one medication profile: name, class, formulation, onset, duration, dose times, repeat days and
/// active state. Delete is at the bottom of an existing profile and asks first.
struct MedicationEditorView: View {
    let model: MedicationsModel
    let isNew: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var draft: MedicationProfile
    @State private var confirmingDelete = false
    @State private var saving = false

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
                            Text("\(draft.onsetMinutes) min").monospacedDigit()
                        }
                    }
                    Stepper(value: $draft.durationMinutes, in: 15...1440, step: 15) {
                        LabeledContent("Duration") {
                            Text("\(draft.durationMinutes) min").monospacedDigit()
                        }
                    }
                } header: {
                    Text("Effect")
                } footer: {
                    Text("Minutes from a dose to the start of its effect, and how long the effect lasts.")
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
                            draft.scheduleMinutesOfDay.append(draft.scheduleMinutesOfDay.last ?? 8 * 60)
                        }
                    }
                } header: {
                    Text("Schedule")
                } footer: {
                    Text(scheduleKind.wrappedValue == .daily
                        ? "Scheduled doses count as taken on the days they fall due until you log or skip them."
                        : "No schedule. Each dose is logged on the check-in when it is taken.")
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

                Section {
                    Toggle("Active", isOn: $draft.active)
                } footer: {
                    Text("Inactive medications add no check-in rows, doses or shading.")
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

    /// Daily at specific times, or as needed. As needed is an empty schedule, which yields doses only where a dose
    /// was logged. Choosing Daily restores one 08:00 time.
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
                        draft.scheduleMinutesOfDay = [8 * 60]
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
