import SwiftUI

/// A ring that fills to `fraction`, with round caps and a track at low opacity of the same colour (Apple Fitness style).
/// The label sits in the middle. VoiceOver reads `summary` in place of the drawn ring.
struct RingProgress<Content: View>: View {
    let fraction: Double
    /// Read out by VoiceOver in place of the drawn ring.
    let summary: String
    var tint: Color = Palette.category(.activity)
    var lineWidth: CGFloat = Spacing.s12
    @ViewBuilder let label: () -> Content

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .stateAnimation(fraction)
            label()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
    }
}
