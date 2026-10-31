import Metrics
import Store
import SwiftUI

/// Keys for a workout in progress. The start time is kept in `@AppStorage`, so a backgrounded or relaunched app
/// comes back to the running workout instead of losing it.
enum ActivityRecording {
    /// Epoch seconds of the start, 0 when nothing is recording.
    static let startKey = "activity.recording.start"
    /// The `ActivityKind` raw value picked for the workout.
    static let kindKey = "activity.recording.kind"
}

/// Pick a kind, start, and stop to save a `manual` activity. While recording: elapsed time, live heart rate from the band,
/// and a running strain and kcal estimate from the closed minutes. Entry view for the Activities stream
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
        ScrollView {
            if isRecording {
                runningContent
            } else {
                setupContent
            }
        }
        .dashboardBackground()
        .navigationTitle(isRecording ? "Recording" : "Record activity")
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
        VStack(spacing: Spacing.s24) {
            DashboardCard(title: "Kind", symbol: "figure.run", tint: Palette.strain) {
                Picker("Kind", selection: kindBinding) {
                    ForEach(ActivityKind.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.menu)
            }
            Text("Starts when you tap Start. The band keeps recording while the app is closed.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .pagePadding()
        .padding(.vertical, Spacing.s8)
    }

    private var runningContent: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = Int(context.date.timeIntervalSince1970 - startedAt)
            VStack(spacing: Spacing.s24) {
                DashboardCard(title: kind.label, symbol: "timer", tint: Palette.strain) {
                    Text(ActivitiesModel.elapsedText(seconds: elapsed))
                        .font(.heroValue)
                        .monospacedDigit()
                    Text("Elapsed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: Spacing.s12) {
                    StatTile(title: "Heart rate", value: liveState.latestBPM.map { Format.bpm($0) } ?? "--")
                    StatTile(title: "Strain", value: estimate?.strain.map { "\(ActivitiesModel.strainText($0)) / 21" } ?? "--")
                }
                StatTile(title: "Calories", value: estimate?.kcal.map { Format.kcal($0) } ?? "--")
                Text("Strain and calories are estimated from closed minutes, so they trail by about a minute.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let errorText {
                    Text(errorText)
                        .font(.subheadline)
                        .foregroundStyle(Palette.error)
                }
            }
            .pagePadding()
            .padding(.vertical, Spacing.s8)
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
