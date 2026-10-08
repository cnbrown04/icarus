import SwiftUI

/// A rounded card with a symbol and a title (IOS_UI_SPEC, Design). Wrap it in a NavigationLink to make it tappable.
struct DashboardCard<Content: View>: View {
    let title: String
    let symbol: String
    var tint: Color = Palette.heartRate
    var showsChevron = false
    var pulses = false
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s12) {
            HStack(spacing: Spacing.s8) {
                Image(systemName: symbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
                    .symbolEffect(.pulse, isActive: pulses && !reduceMotion)
                Text(title)
                    .font(.headline)
                Spacer(minLength: Spacing.s8)
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.s16)
        .cardBackground()
    }
}
