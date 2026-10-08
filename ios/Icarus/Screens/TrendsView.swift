import SwiftUI

struct TrendsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s8) {
            Text("No trends yet")
                .font(.body.weight(.semibold))
            Text("Trends appear after a day of band data.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .pagePadding()
        .navigationTitle("Trends")
    }
}
