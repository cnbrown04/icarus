import Metrics
import SwiftUI

/// Day strain on a 270 degree dial over WHOOP's 0 to 21 axis. The value arc fills to `strain`, and the Strain
/// Coach target band sits on the same arc in a paler tint, so the two read together. The gap is at the bottom.
struct StrainDial: View {
    /// Day strain on 0 to 21, or nil when the day has too little data to score.
    let strain: Double?
    let target: StrainTarget
    var lineWidth: CGFloat = Spacing.s16

    /// The dial sweeps 270 degrees (three quarters of a turn), starting at 7:30 on the clock.
    private static let sweep = 0.75
    private static let startDegrees = 135.0

    var body: some View {
        ZStack {
            dialArc(from: 0, to: 1, tint: Palette.strain.opacity(0.15), cap: .round)
            dialArc(
                from: target.low / StrainCoach.scaleMax,
                to: target.high / StrainCoach.scaleMax,
                tint: Palette.strain.opacity(0.35),
                cap: .butt
            )
            dialArc(from: 0, to: fraction, tint: Palette.strain, cap: .round)
                .stateAnimation(fraction)
            VStack(spacing: Spacing.s4) {
                Text(valueText)
                    .font(.heroValue)
                    .monospacedDigit()
                    .liveNumberTransition()
                    .stateAnimation(fraction)
                Text("of 21")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Day strain")
        .accessibilityValue(accessibilityText)
    }

    private var fraction: Double {
        guard let strain, strain.isFinite else { return 0 }
        return min(max(strain / StrainCoach.scaleMax, 0), 1)
    }

    private var valueText: String {
        strain.map { String(format: "%.1f", $0) } ?? "--"
    }

    private var accessibilityText: String {
        let value = strain.map { String(format: "%.1f of 21", $0) } ?? "No value"
        return "\(value). Target \(target.low.formatted()) to \(target.high.formatted()), \(target.label.lowercased())."
    }

    /// One stretch of the dial, as fractions of the full 0 to 21 scale. A trimmed circle starts at 3 o'clock and
    /// runs clockwise, so it is turned 135 degrees to start at 7:30.
    private func dialArc(from lower: Double, to upper: Double, tint: Color, cap: CGLineCap) -> some View {
        Circle()
            .trim(from: Self.sweep * min(max(lower, 0), 1), to: Self.sweep * min(max(upper, 0), 1))
            .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: cap))
            .rotationEffect(.degrees(Self.startDegrees))
    }
}
