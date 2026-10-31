import SwiftUI

/// A change against the previous period, with a direction symbol. Colour is neutral: a rise is not a good or bad sign by itself.
struct DeltaChip: View {
    let change: Double
    let unit: String

    private var rounded: Int { Int(change.rounded()) }

    private var text: String {
        let sign = rounded > 0 ? "+" : ""
        return unit.isEmpty ? "\(sign)\(rounded)" : "\(sign)\(rounded) \(unit)"
    }

    private var symbol: String {
        if rounded > 0 { return "arrow.up.right" }
        if rounded < 0 { return "arrow.down.right" }
        return "arrow.right"
    }

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Spacing.s8)
            .padding(.vertical, Spacing.s4)
            .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
    }
}
