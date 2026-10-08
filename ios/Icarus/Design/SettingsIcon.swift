import SwiftUI

/// A white symbol on a coloured rounded square, as in the system Settings app (IOS_UI_SPEC, Settings).
struct SettingsIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: Spacing.s32, height: Spacing.s32)
            .background(tint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
    }
}
