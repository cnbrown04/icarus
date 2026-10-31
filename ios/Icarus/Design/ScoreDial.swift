import SwiftUI

/// A large score ring for the Overview: a value in the middle, a title and one caption under it. It follows
/// `RingProgress` (round caps, a tinted track, a fill that animates on state change) and adds an optional target
/// band drawn on the same track, which the Strain dial uses for the Strain Coach target.
struct ScoreDial: View {
    let title: String
    /// Fill of the ring, 0...1. Values outside the range are clamped.
    let fraction: Double
    let valueText: String
    var unit: String?
    var caption: String?
    var tint: Color = Palette.neutral
    /// Target band as fractions of the full ring, drawn paler behind the fill.
    var band: ClosedRange<Double>?
    let accessibilityValue: String

    private static let lineWidth = Spacing.s12

    var body: some View {
        VStack(spacing: Spacing.s8) {
            ZStack {
                Circle()
                    .stroke(tint.opacity(0.2), lineWidth: Self.lineWidth)
                if let band {
                    Circle()
                        .trim(from: band.lowerBound, to: band.upperBound)
                        .stroke(tint.opacity(0.35), style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                }
                Circle()
                    .trim(from: 0, to: min(max(fraction, 0), 1))
                    .stroke(tint, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .stateAnimation(fraction)
                VStack(spacing: Spacing.s4) {
                    Text(valueText)
                        .font(.metricValue)
                        .monospacedDigit()
                        .liveNumberTransition()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if let unit {
                        Text(unit)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: Spacing.s48 * 2, height: Spacing.s48 * 2)

            Text(title)
                .font(.caption.weight(.semibold))
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
    }
}
