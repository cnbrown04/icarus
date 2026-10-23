import Metrics
import Store
import SwiftUI

/// Corrects one night's bed and wake times, or deletes a falsely detected night. Each change is a
/// `sleep_edit` row in the store, so it survives every re-derivation (`SleepEdits.swift`); the store
/// refuses a window that is inverted, out of bounds, in the future, overlapping, or unrecorded, and the
/// refusal is shown here as written.
struct SleepEditView: View {
    let environment: AppEnvironment
    let night: Dashboard.SleepSnapshot.Night
    let timeZone: TimeZone
    /// Called after a change is stored, so the Sleep list reloads at once instead of on its next tick.
    let onChange: () -> Void

    @State private var bed: Date
    @State private var wake: Date
    @State private var errorMessage: String?
    @State private var isWorking = false
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss

    init(environment: AppEnvironment, night: Dashboard.SleepSnapshot.Night, timeZone: TimeZone, onChange: @escaping () -> Void) {
        self.environment = environment
        self.night = night
        self.timeZone = timeZone
        self.onChange = onChange
        _bed = State(initialValue: Date(epochMs: night.startMs))
        _wake = State(initialValue: Date(epochMs: night.startMs + night.durationS * 1_000))
    }

    /// Calendar in the device zone, so the pickers' days and times match the Sleep list's clock.
    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        return calendar
    }

    private var endMs: Int64 { night.startMs + night.durationS * 1_000 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Bed", selection: $bed, displayedComponents: [.date, .hourAndMinute])
                        .accessibilityIdentifier("sleepEdit.bed")
                    DatePicker("Wake", selection: $wake, displayedComponents: [.date, .hourAndMinute])
                        .accessibilityIdentifier("sleepEdit.wake")
                } footer: {
                    Text("Times are in the device time zone. A night must be 30 minutes to 16 hours long, cannot end in the future, and needs band data inside it.")
                }

                Section {
                    Button("Delete night", role: .destructive) {
                        confirmDelete = true
                    }
                    .accessibilityIdentifier("sleepEdit.delete")
                    if night.isEdited {
                        Button("Restore detected times") {
                            restoreDetected()
                        }
                        .accessibilityIdentifier("sleepEdit.restore")
                    }
                } footer: {
                    Text("A deleted night stays deleted: detection will not bring it back.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("sleepEdit.error")
                    }
                }
            }
            .environment(\.timeZone, timeZone)
            .environment(\.calendar, calendar)
            .navigationTitle("Edit times")
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
                    .disabled(isWorking)
                    .accessibilityIdentifier("sleepEdit.save")
                }
            }
            .confirmationDialog("Delete this night?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete night", role: .destructive) {
                    deleteNight()
                }
            }
        }
    }

    // MARK: Writes

    /// Stores the corrected bed and wake. Minute precision, and an unchanged pair is a plain close, so
    /// opening and closing the sheet never creates a correction.
    private func save() {
        let startMs = Self.minute(bed)
        let newEndMs = Self.minute(wake)
        guard startMs != night.startMs || newEndMs != endMs else {
            dismiss()
            return
        }
        let zone = timeZone
        let original = night
        let nowMs = environment.clock.nowMs
        perform {
            try await environment.database.writer.write { db in
                try db.retimeSleepSession(
                    bandID: original.bandID,
                    sessionStartMs: original.startMs,
                    sessionEndMs: original.startMs + original.durationS * 1_000,
                    newStartMs: startMs,
                    newEndMs: newEndMs,
                    in: zone,
                    nowMs: nowMs
                )
            }
        }
    }

    private func deleteNight() {
        let zone = timeZone
        let original = night
        let nowMs = environment.clock.nowMs
        perform {
            try await environment.database.writer.write { db in
                try db.dismissSleepSession(
                    bandID: original.bandID,
                    sessionStartMs: original.startMs,
                    sessionEndMs: original.startMs + original.durationS * 1_000,
                    in: zone,
                    nowMs: nowMs
                )
            }
        }
    }

    private func restoreDetected() {
        let zone = timeZone
        let original = night
        let nowMs = environment.clock.nowMs
        perform {
            _ = try await environment.database.writer.write { db in
                try db.removeSleepEdit(
                    bandID: original.bandID,
                    sessionStartMs: original.startMs,
                    sessionEndMs: original.startMs + original.durationS * 1_000,
                    in: zone,
                    nowMs: nowMs
                )
            }
        }
    }

    /// Runs one store write off the main thread (GRDB's async write), then reloads the list and closes
    /// the sheet. A refused correction keeps the sheet open with the store's reason.
    private func perform(_ write: @escaping () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await write()
                isWorking = false
                onChange()
                dismiss()
            } catch let error as SleepEditError {
                errorMessage = error.errorDescription
                isWorking = false
            } catch {
                errorMessage = "The change could not be saved. \(error.localizedDescription)"
                isWorking = false
            }
        }
    }

    /// Epoch ms of a picked time, floored to the minute.
    private static func minute(_ date: Date) -> Int64 {
        let ms = Int64((date.timeIntervalSince1970 * 1_000).rounded(.down))
        return ms - ms % 60_000
    }
}
