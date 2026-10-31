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

/// Every workout over the last 30 local days, grouped by day. Auto-detected and recorded rows share the list.
/// Rows link by `AppRoute`. Entry view for the workouts list (`environment`, `liveState`).
struct ActivitiesListView: View {
    let environment: AppEnvironment
    let liveState: LiveState

    @State private var list: ActivitiesModel.ListSnapshot?
    @State private var isRecording = false
    @AppStorage(ActivityRecording.startKey) private var recordingStart: Double = 0

    var body: some View {
        List {
            if recordingStart > 0 {
                Section {
                    Button {
                        isRecording = true
                    } label: {
                        HStack {
                            Text("Recording")
                            Spacer(minLength: Spacing.s8)
                            Text("Resume")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if list?.days.isEmpty == true, recordingStart == 0 {
                Section {
                    EmptyStateRow(text: "No workouts in the last 30 days", actionTitle: "Record") {
                        isRecording = true
                    }
                }
            }
            ForEach(list?.days ?? []) { day in
                Section(day.title) {
                    ForEach(day.activities, id: \.id) { row in
                        NavigationLink(value: AppRoute.workout(id: row.id)) {
                            ActivityRowView(row: row, timeZone: list?.timeZone ?? .current)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Workouts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isRecording = true
                } label: {
                    Image(systemName: Symbol.record)
                }
                .accessibilityLabel("Record activity")
            }
        }
        .sheet(isPresented: $isRecording) {
            NavigationStack {
                RecordActivityView(environment: environment, liveState: liveState)
            }
        }
        .task {
            await ActivitiesModel.refreshDetection(in: environment.database, nowMs: environment.clock.nowMs)
        }
        .task {
            for await value in environment.snapshots(every: .seconds(30), { db, nowMs in
                try ActivitiesModel.list(db, nowMs: nowMs)
            }) {
                list = value
            }
        }
    }
}

/// One workout as a row: its kind glyph, name, then start time and duration, with its strain on the right.
struct ActivityRowView: View {
    let row: ActivityRow
    let timeZone: TimeZone

    private var detail: String {
        let when = Format.clock(row.startMs, in: timeZone)
        let length = Format.duration((row.endMs - row.startMs) / 1000)
        return "\(when) · \(length)"
    }

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.s12) {
            Image(systemName: row.activityKind.symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(MetricCategory.activity.color)
            VStack(alignment: .leading, spacing: Spacing.s4) {
                Text(row.displayName)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Spacing.s8)
            Text(ActivitiesModel.strainText(row.strain))
                .font(.figure)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}
