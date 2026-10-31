import Metrics
import SwiftUI

/// Dots for the three stress bands. Still used by the stress screen until Wave C retires it.
struct StressLegend: View {
    private let bands: [StressBand] = [.low, .moderate, .high]

    var body: some View {
        HStack(spacing: Spacing.s16) {
            ForEach(Array(bands.enumerated()), id: \.offset) { _, band in
                HStack(spacing: Spacing.s4) {
                    Circle()
                        .fill(Palette.stress(band))
                        .frame(width: Spacing.s8, height: Spacing.s8)
                    Text(Format.bandName(band))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
