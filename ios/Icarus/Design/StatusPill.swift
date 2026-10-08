import BandKit
import SwiftUI

/// A capsule with a symbol and a short state word, in a semantic colour (IOS_UI_SPEC, Design).
struct StatusPill: View {
    let text: String
    let symbol: String
    var tint: Color = Palette.neutral

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, Spacing.s12)
            .padding(.vertical, Spacing.s4)
            .background(tint.opacity(0.15), in: Capsule())
    }
}

extension StatusPill {
    /// The band link state, from the live state.
    @MainActor
    static func link(_ liveState: LiveState) -> StatusPill {
        StatusPill(
            text: liveState.connectionText,
            symbol: liveState.connectionSymbol,
            tint: Palette.link(liveState.state)
        )
    }
}
