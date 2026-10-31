import Foundation
import Metrics
import Store
import SwiftUI

/// The morning check-in (IOS_UI_SPEC journal): answers for one day, yes or no, plus the day's medication doses.
/// WHOOP asks in the morning about the day before, so the default day is yesterday. Days can be stepped back, and
/// not forward past today. Pass `day` to open a specific day; leave it nil for yesterday.
struct JournalView: View {
    let environment: AppEnvironment

    @State private var model: JournalModel

    init(environment: AppEnvironment, day: LocalDay? = nil) {
        self.environment = environment
        _model = State(initialValue: JournalModel(database: environment.database, clock: environment.clock, day: day))
    }

    var body: some View {
        List {
            Section {
                dayPager
            }

            if let snapshot = model.snapshot {
                Section {
                    ForEach(snapshot.questions.filter(\.enabled)) { question in
                        QuestionRow(question: question, answer: snapshot.answers[question.id]) { value in
                            Task { await model.setAnswer(question.id, value: value) }
                        }
                    }
                } footer: {
                    Text("Answers feed Journal insights. Turn questions off in the check-in editor.")
                }

                if !snapshot.medications.isEmpty {
                    Section {
                        ForEach(snapshot.medications) { row in
                            MedicationDoseRow(row: row, timeZone: snapshot.timeZone, model: model)
                        }
                    } header: {
                        Text("Medications")
                    } footer: {
                        if snapshot.medications.contains(where: { !$0.isAsNeeded && $0.logged == .none }) {
                            Text("Scheduled doses count as taken until you log or skip them.")
                        }
                    }
                }
            }

            if let message = model.errorMessage {
                Section {
                    Text(message).foregroundStyle(Palette.error)
                }
            }

            Section {
                NavigationLink {
                    JournalInsightsView(environment: environment)
                } label: {
                    Text("Journal insights")
                }
                .accessibilityIdentifier("journal.insights")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Journal")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.load()
        }
        .refreshable {
            await model.load()
        }
    }

    private var dayPager: some View {
        let zone = model.snapshot?.timeZone ?? .current
        let isYesterday = model.day == LocalTime.adding(days: -1, to: model.today)
        return HStack {
            Button {
                Task { await model.move(by: -1) }
            } label: {
                Image(systemName: "chevron.left")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Previous day")
            .accessibilityIdentifier("journal.previousDay")

            Spacer()

            VStack(spacing: Spacing.s4) {
                Text(JournalFormat.dayTitle(model.day, in: zone))
                    .font(.headline)
                if isYesterday {
                    Text("Yesterday")
                        .font(.caption)
                        .foregroundStyle(Palette.neutral)
                }
            }

            Spacer()

            Button {
                Task { await model.move(by: 1) }
            } label: {
                Image(systemName: "chevron.right")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(!JournalFormat.isAfter(model.today, model.day))
            .accessibilityLabel("Next day")
            .accessibilityIdentifier("journal.nextDay")
        }
        .buttonStyle(.borderless)
    }
}

/// One question. Yes/no questions use a segmented Yes / No control, and counts use a stepper.
private struct QuestionRow: View {
    let question: JournalQuestion
    let answer: Int?
    let onChange: (Int?) -> Void

    var body: some View {
        switch question.kind {
        case .yesno:
            VStack(alignment: .leading, spacing: Spacing.s8) {
                Text(question.label)
                Picker(question.label, selection: Binding<Int?>(get: { answer }, set: { onChange($0) })) {
                    Text("Yes").tag(1 as Int?)
                    Text("No").tag(0 as Int?)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("journal.\(question.id)")
            }
        case .count:
            Stepper(value: Binding<Int>(get: { answer ?? 0 }, set: { onChange($0) }), in: 0...99) {
                LabeledContent(question.label) {
                    Text("\(answer ?? 0)").monospacedDigit()
                }
            }
        }
    }
}

/// One active medication on the day.
///
/// A scheduled medication shows its schedule as assumed taken, with Taken and Skipped. Once logged, it shows the time
/// picker or Skipped, and can be reset to the schedule. An as-needed medication (no schedule) shows Not taken until
/// a dose is logged. Each logged dose is listed and can be removed, and another can be added.
private struct MedicationDoseRow: View {
    let row: JournalModel.MedicationRow
    let timeZone: TimeZone
    let model: JournalModel

    /// The time the next as-needed dose will be logged at. Starts at now, and resets when the day changes.
    @State private var asNeededTime: Date

    init(row: JournalModel.MedicationRow, timeZone: TimeZone, model: JournalModel) {
        self.row = row
        self.timeZone = timeZone
        self.model = model
        _asNeededTime = State(initialValue: Date(epochMs: model.defaultAsNeededMs()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s8) {
            Text(row.profile.name)
            Text(statusCaption)
                .font(.caption)
                .foregroundStyle(Palette.neutral)

            if row.isAsNeeded || row.scheduledMs.isEmpty {
                asNeededControls
            } else {
                scheduledControls
            }
        }
        .padding(.vertical, Spacing.s4)
        .onChange(of: model.day) {
            asNeededTime = Date(epochMs: model.defaultAsNeededMs())
        }
    }

    @ViewBuilder
    private var scheduledControls: some View {
        switch row.logged {
        case .none:
            HStack(spacing: Spacing.s12) {
                Button("Taken") {
                    Task { await model.logTaken(row.profile.id, atMs: row.scheduledMs.first ?? model.defaultAsNeededMs()) }
                }
                .accessibilityIdentifier("journal.taken.\(row.profile.id)")
                Button("Skipped") {
                    Task { await model.logSkipped(row.profile.id) }
                }
                .accessibilityIdentifier("journal.skipped.\(row.profile.id)")
            }
            .buttonStyle(.bordered)
        case .taken(let times):
            if times.count == 1, let atMs = times.first {
                DatePicker(
                    "Taken at",
                    selection: Binding<Date>(
                        get: { Date(epochMs: atMs) },
                        set: { newValue in
                            let next = model.takenMs(for: newValue)
                            Task { await model.logTaken(row.profile.id, atMs: next) }
                        }
                    ),
                    displayedComponents: .hourAndMinute
                )
                .accessibilityIdentifier("journal.takenTime.\(row.profile.id)")
            } else {
                Text("Taken at " + times.map { JournalFormat.clock($0, in: timeZone) }.joined(separator: ", "))
                    .font(.subheadline)
            }
            resetButton
        case .skipped:
            Text("Skipped")
                .font(.subheadline)
            resetButton
        }
    }

    @ViewBuilder
    private var asNeededControls: some View {
        ForEach(row.takenEntries) { entry in
            HStack {
                Text("Taken at " + JournalFormat.clock(entry.override.takenMs ?? 0, in: timeZone))
                    .font(.subheadline)
                Spacer()
                Button {
                    Task { await model.removeEntry(entry.id) }
                } label: {
                    Image(systemName: "minus.circle")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove dose at " + JournalFormat.clock(entry.override.takenMs ?? 0, in: timeZone))
            }
        }
        DatePicker("Dose time", selection: $asNeededTime, displayedComponents: .hourAndMinute)
            .accessibilityIdentifier("journal.asNeededTime.\(row.profile.id)")
        Button("Took one at " + JournalFormat.clock(model.takenMs(for: asNeededTime), in: timeZone)) {
            Task { await model.addAsNeededDose(row.profile.id, atMs: model.takenMs(for: asNeededTime)) }
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("journal.tookOne.\(row.profile.id)")
    }

    private var resetButton: some View {
        Button("Reset to schedule") {
            Task { await model.resetDose(row.profile.id) }
        }
        .font(.subheadline)
        .buttonStyle(.borderless)
    }

    /// Says in words whether the day is the schedule (assumed) or what was logged.
    private var statusCaption: String {
        if row.isAsNeeded {
            let count = row.takenEntries.count
            return count == 0 ? "Not taken" : "Taken \(count) \(count == 1 ? "time" : "times")"
        }
        if row.scheduledMs.isEmpty {
            return "Not scheduled today"
        }
        switch row.logged {
        case .none:
            let times = row.scheduledMs.map { JournalFormat.clock($0, in: timeZone) }.joined(separator: ", ")
            return "Scheduled \(times) · assumed taken"
        case .taken, .skipped:
            return "Logged"
        }
    }
}

/// Formatting shared by the journal screens. Day and clock text use the profile's zone, not the device's.
enum JournalFormat {
    /// True when `lhs` is a later calendar day than `rhs`. `LocalDay` is not `Comparable`.
    static func isAfter(_ lhs: LocalDay, _ rhs: LocalDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) > (rhs.year, rhs.month, rhs.day)
    }

    static func dayTitle(_ day: LocalDay, in zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = zone
        formatter.setLocalizedDateFormatFromTemplate("EEEdMMM")
        return formatter.string(from: Date(epochMs: LocalTime.localTime(day, hour: 12, in: zone)))
    }

    static func clock(_ ms: Int64, in zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = zone
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: Date(epochMs: ms))
    }
}
