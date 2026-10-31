import Metrics
import Store
import SwiftUI

/// Every activity over the last 30 local days, grouped by day. Auto-detected and recorded rows share the list.
/// Entry view for the Activities stream (`environment`, `liveState`).
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
                                .font(.headline)
                            Spacer(minLength: Spacing.s8)
                            Text("Resume")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            ForEach(list?.days ?? []) { day in
                Section(day.title) {
                    ForEach(day.activities, id: \.id) { row in
                        NavigationLink {
                            ActivityDetailView(environment: environment, activityID: row.id)
                        } label: {
                            ActivityRowView(row: row, timeZone: list?.timeZone ?? .current)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if list?.days.isEmpty == true, recordingStart == 0 {
                VStack(spacing: Spacing.s12) {
                    Text("No activities")
                        .font(.headline)
                    Text("Activities detected from heart rate appear here, or record one now.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Record activity") {
                        isRecording = true
                    }
                    .buttonStyle(.bordered)
                }
                .padding(Spacing.s24)
            }
        }
        .navigationTitle("Activities")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Record") {
                    isRecording = true
                }
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

/// One activity as a row: name or kind, start time and duration, then its strain on the 0-21 axis.
struct ActivityRowView: View {
    let row: ActivityRow
    let timeZone: TimeZone

    private var durationSeconds: Int64 {
        (row.endMs - row.startMs) / 1000
    }

    private var detail: String {
        let when = Format.clock(row.startMs, in: timeZone)
        let length = Format.duration(durationSeconds)
        return row.isAuto ? "\(when) · \(length) · Detected" : "\(when) · \(length)"
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s12) {
            VStack(alignment: .leading, spacing: Spacing.s4) {
                Text(row.displayName)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Spacing.s8)
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s4) {
                Text(ActivitiesModel.strainText(row.strain))
                    .font(.metricValue)
                    .monospacedDigit()
                if row.strain != nil {
                    Text("/ 21")
                        .font(.metricUnit)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
