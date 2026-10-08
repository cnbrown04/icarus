import SwiftUI

struct AlarmsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s8) {
            Text("No alarms")
                .font(.body.weight(.semibold))
            Button("New alarm") {
                // TODO(PLAN.md §14, Phase 5): open the alarm editor.
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .pagePadding()
        .navigationTitle("Alarms")
        .accessibilityIdentifier("tab.alarms")
    }
}
