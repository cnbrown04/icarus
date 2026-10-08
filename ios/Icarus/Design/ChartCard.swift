import SwiftUI

/// A card for one chart: title, a summary beside or under it, the chart and an optional footer (IOS_UI_SPEC, Design).
struct ChartCard<Summary: View, Chart: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder let summary: () -> Summary
    @ViewBuilder let chart: () -> Chart

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s12) {
            Text(title)
                .font(.headline)
            summary()
            chart()
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.s16)
        .cardBackground()
    }
}
