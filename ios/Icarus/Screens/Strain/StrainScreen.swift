import Metrics
import Store
import SwiftUI

/// The Strain tab as the app shell wires it: `StrainTabView` for the content, plus the Record action (the primary
/// action), today's activities with a link to the full list, and the recording sheet.
struct StrainScreen: View {
    let environment: AppEnvironment
    let liveState: LiveState

    /// Today in the profile's zone. Nil until the first read, and the activities slot stays hidden until then.
    @State private var today: LocalDay?
    @State private var isRecording = false

    var body: some View {
        StrainTabView(environment: environment, liveState: liveState, activitiesSlot: activitiesSlot)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Record") {
                        isRecording = true
                    }
                    .accessibilityIdentifier("strain.record")
                }
            }
            .sheet(isPresented: $isRecording) {
                NavigationStack {
                    RecordActivityView(environment: environment, liveState: liveState)
                }
            }
            .task {
                for await value in environment.snapshots(every: .seconds(300), { db, nowMs in
                    try Dashboard.Context.load(db, nowMs: nowMs).today
                }) {
                    today = value
                }
            }
    }

    private var activitiesSlot: AnyView? {
        guard let today else { return nil }
        return AnyView(
            VStack(alignment: .leading, spacing: Spacing.s12) {
                ActivitiesSection(environment: environment, day: today)
                NavigationLink {
                    ActivitiesListView(environment: environment, liveState: liveState)
                } label: {
                    HStack(spacing: Spacing.s8) {
                        Text("All activities")
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: Spacing.s8)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(minHeight: Spacing.s48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens every activity from the last 30 days")
            }
        )
    }
}
