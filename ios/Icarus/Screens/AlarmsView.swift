import SwiftUI

/// Alarms are Phase 5. Until then the screen is the empty state: one line and one action.
struct AlarmsView: View {
    var body: some View {
        VStack(spacing: Spacing.s16) {
            Text("No alarms")
                .font(.headline)
            Button("New alarm") {
                // TODO(PLAN.md §14, Phase 5): open the alarm editor.
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .pagePadding()
        .navigationTitle("Alarms")
    }
}
