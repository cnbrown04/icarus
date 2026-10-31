import Foundation
import Metrics
import Store
import SwiftUI

/// The morning check-in (IOS_UI_SPEC journal): behaviour answers for one day, yes or no or a count. Medications are not
/// part of the check-in; they are set once in Settings-style Medications.
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
                    .frame(minWidth: MinTouch.size, minHeight: MinTouch.size)
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
                    .frame(minWidth: MinTouch.size, minHeight: MinTouch.size)
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

}
