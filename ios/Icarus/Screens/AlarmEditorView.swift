import AlarmKitBridge
import SwiftUI

/// The alarm editor (IOS_UI_SPEC, Screen 13): label, time, repeat days, rhythm, channels and Test, in a Form.
/// Save writes the alarm locally and sends it to the server when it can. The phone channel is always on (PLAN.md 6.5).
struct AlarmEditorView: View {
    let environment: AppEnvironment
    let liveState: LiveState

    @State private var draft: AlarmDraft
    @State private var testMessage: String?
    @Environment(\.dismiss) private var dismiss

    private let isNew: Bool

    init(environment: AppEnvironment, liveState: LiveState, initial: AlarmDraft) {
        self.environment = environment
        self.liveState = liveState
        _draft = State(initialValue: initial)
        isNew = initial.id == nil
    }

    /// The rhythm picker's choices: a built-in name, or custom steps (edited in the rhythm editor).
    private enum RhythmChoice: Hashable {
        case builtIn(BuiltInRhythm)
        case custom
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Label", text: $draft.label)
                        .accessibilityIdentifier("alarmEditor.label")
                    LabeledContent("Type", value: "Scheduled")
                    DatePicker("Time", selection: $draft.time, displayedComponents: .hourAndMinute)
                        .accessibilityIdentifier("alarmEditor.time")
                }

                Section {
                    WeekdayChips(selection: $draft.weekdays)
                } header: {
                    Text("Repeat")
                } footer: {
                    if draft.weekdays.isEmpty {
                        Text("No days chosen. The alarm rings once, at the next time.")
                    }
                }

                Section {
                    Picker("Rhythm", selection: rhythmChoice) {
                        ForEach(BuiltInRhythm.allCases, id: \.self) { name in
                            Text(name.title).tag(RhythmChoice.builtIn(name))
                        }
                        Text("Custom").tag(RhythmChoice.custom)
                    }
                    NavigationLink {
                        RhythmEditorView(rhythm: $draft.rhythm, liveState: liveState)
                    } label: {
                        Text("Edit steps")
                    }
                    .accessibilityIdentifier("alarmEditor.rhythm")
                } header: {
                    Text("Rhythm")
                }

                Section {
                    Toggle("Phone", isOn: .constant(true))
                        .disabled(true)
                    Toggle("Band", isOn: $draft.bandChannel)
                        .accessibilityIdentifier("alarmEditor.band")
                } header: {
                    Text("Channels")
                } footer: {
                    Text(draft.bandChannel
                        ? "The phone alarm is always armed. Band alarms depend on the band clock."
                        : "The phone alarm is always armed. Turn on the band channel on Device to use the band.")
                }

                Section {
                    Button("Test") {
                        Task { testMessage = await environment.alarms.testLocally(draft) }
                    }
                    .accessibilityIdentifier("alarmEditor.test")
                    if let testMessage {
                        Text(testMessage)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(isNew ? "New alarm" : "Alarm")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            try? await environment.alarms.save(draft)
                            dismiss()
                        }
                    }
                    .accessibilityIdentifier("alarmEditor.save")
                }
            }
        }
    }

    private var rhythmChoice: Binding<RhythmChoice> {
        Binding(
            get: {
                switch draft.rhythm {
                case let .builtIn(name): return .builtIn(name)
                case .custom: return .custom
                }
            },
            set: { choice in
                switch choice {
                case let .builtIn(name):
                    draft.rhythm = .builtIn(name)
                case .custom:
                    // Choosing Custom starts from the built-in's steps, so the editor opens on something real.
                    if case let .builtIn(name) = draft.rhythm, let rhythm = try? RhythmSpec.builtIn(name).rhythm() {
                        draft.rhythm = .custom(rhythm)
                    }
                }
            }
        )
    }
}
