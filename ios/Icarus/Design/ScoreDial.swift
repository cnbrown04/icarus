import SwiftUI

/// A score ring in the Apple Fitness style: a track at low opacity of the ring colour, round caps, and the value in
/// the middle. A percent unit is set beside the figure ("47%"); other units sit under it. The optional target band is
/// drawn on the same track, which the Strain ring uses for the Strain Coach target. The init is shared with the
/// Strain tab, so keep its parameters.
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
    private static let diameter = Spacing.s48 * 2

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
                    figure
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .liveNumberTransition()
                    if let unit, unit != "%" {
                        Text(unit)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(Self.lineWidth)
            }
            .frame(width: Self.diameter, height: Self.diameter)

            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let caption {
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
    }

    /// The figure, with a "%" unit on the same line as the value so it never wraps onto its own line.
    private var figure: Text {
        let value = Text(valueText).font(.figure)
        guard unit == "%" else { return value }
        return value + Text("%").font(.figureUnit).foregroundStyle(.secondary)
    }
}
