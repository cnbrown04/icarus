import Metrics
import Store
import SwiftUI

/// Pick a kind, start, and stop to save a `manual` workout. While recording: elapsed time, live heart rate from the
/// band, and a running strain and calorie estimate from the closed minutes. Entry view for recording
/// (`environment`, `liveState`).
struct RecordActivityView: View {
    let environment: AppEnvironment
    let liveState: LiveState

    @Environment(\.dismiss) private var dismiss
    @AppStorage(ActivityRecording.startKey) private var startedAt: Double = 0
    @AppStorage(ActivityRecording.kindKey) private var kindRaw: String = ActivityKind.run.rawValue
    @State private var estimate: ActivitySummary?
    @State private var confirmDiscard = false
    @State private var saving = false
    @State private var errorText: String?

    private var isRecording: Bool {
        startedAt > 0
    }

    private var kind: ActivityKind {
        ActivityKind(rawValue: kindRaw) ?? .run
    }

    private var kindBinding: Binding<ActivityKind> {
        Binding(get: { kind }, set: { kindRaw = $0.rawValue })
    }

    var body: some View {
        List {
            if isRecording {
                runningContent
            } else {
                setupContent
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(isRecording ? "Recording" : "Record workout")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isRecording {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        start()
                    }
                }
            } else {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Discard workout", role: .destructive) {
                            confirmDiscard = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Stop") {
                        stop()
                    }
                    .disabled(saving)
                }
            }
        }
        .confirmationDialog("Discard this workout?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard workout", role: .destructive) {
                discard()
            }
        }
        .task(id: startedAt) {
            guard startedAt > 0 else {
                estimate = nil
                return
            }
            let startMs = Int64(startedAt * 1000)
            for await value in environment.snapshots(every: .seconds(15), { db, nowMs in
                try ActivitiesModel.liveEstimate(db, startMs: startMs, nowMs: nowMs)
            }) {
                estimate = value
            }
        }
    }

    private var setupContent: some View {
        Section {
            Picker("Kind", selection: kindBinding) {
                ForEach(ActivityKind.allCases, id: \.self) { option in
                    Text(option.label).tag(option)
                }
            }
        }
    }

    @ViewBuilder
    private var runningContent: some View {
        Section {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = Int(context.date.timeIntervalSince1970 - startedAt)
                Text(ActivitiesModel.elapsedText(seconds: elapsed))
                    .font(.figureLarge)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, Spacing.s4)
            }
        }
        Section {
            LabeledContent("Heart rate") {
                LiveBPMText(liveState: liveState)
            }
            LabeledContent("Strain") {
                Text(ActivitiesModel.strainText(estimate?.strain))
                    .monospacedDigit()
            }
            LabeledContent("Calories") {
                Text(ActivitiesModel.kcalText(estimate?.kcal))
                    .monospacedDigit()
            }
        }
        if let errorText {
            Section {
                Text(errorText)
                    .foregroundStyle(Palette.error)
            }
        }
    }

    private func start() {
        startedAt = Date().timeIntervalSince1970
        errorText = nil
    }

    /// Saves the workout from the start to now. The recording stays open if the save fails, so the user can retry.
    private func stop() {
        guard isRecording, !saving else { return }
        let startMs = Int64(startedAt * 1000)
        let nowMs = environment.clock.nowMs
        let kind = kind
        guard nowMs > startMs else {
            startedAt = 0
            dismiss()
            return
        }
        saving = true
        Task {
            do {
                _ = try await environment.database.writer.write { db in
                    try db.saveManualActivity(kind: kind, name: nil, startMs: startMs, endMs: nowMs, computedAtMs: nowMs)
                }
                startedAt = 0
                dismiss()
            } catch {
                errorText = "Could not save the workout. Tap Stop to try again."
            }
            saving = false
        }
    }

    private func discard() {
        startedAt = 0
        errorText = nil
    }
}
