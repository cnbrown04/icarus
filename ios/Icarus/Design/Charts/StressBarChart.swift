import Charts
import Metrics
import SwiftUI

/// Stress as one bar per bucket, coloured by band (IOS_UI_SPEC, Charts). Pair with `StressLegend`.
struct StressBarChart: View {
    let buckets: [StressBucket]

    var body: some View {
        Chart(buckets) { bucket in
            BarMark(x: .value("Time", bucket.start), y: .value("Stress", bucket.average))
                .foregroundStyle(Palette.stress(bucket.band))
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(position: .leading)
        }
        .accessibilityLabel("Stress, 15-minute averages")
    }
}

/// Dots for the three stress bands.
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
