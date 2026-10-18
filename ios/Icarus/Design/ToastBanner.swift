import SwiftUI

/// A short message over the bottom of a screen, in a capsule (IOS_UI_SPEC, Design). The owner decides when it goes.
struct ToastBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.subheadline.weight(.semibold))
            .symbolRenderingMode(.multicolor)
            .padding(.horizontal, Spacing.s16)
            .padding(.vertical, Spacing.s12)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, Spacing.s16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
