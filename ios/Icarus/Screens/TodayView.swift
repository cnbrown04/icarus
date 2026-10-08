import SwiftUI

struct TodayView: View {
    let liveState: LiveState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.s24) {
                heartRateSection

                MetricRow(title: "Stress", value: "Calibrating")
                MetricRow(title: "Calories", value: "1840 kcal", caption: "Estimated")
                MetricRow(title: "Resting HR", value: "--")
                MetricRow(title: "Last sync", value: "Not paired")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .pagePadding()
            .accessibilityIdentifier("tab.today")
        }
        .navigationTitle("Today")
    }

    private var heartRateSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s8) {
            HStack(spacing: Spacing.s8) {
                Circle()
                    .fill(liveState.connection == .connected ? Color.green : Color.secondary)
                    .frame(width: Spacing.s8, height: Spacing.s8)
                Text(liveState.connectionText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: Spacing.s4) {
                heartRateValue
                Text("bpm")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            HeartRateSparkline(samples: liveState.samples)
                .frame(height: Spacing.s48 * 2)

            Text("Last 15 min")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var heartRateValue: some View {
        if let bpm = liveState.latestBPM {
            Text("\(bpm)")
                .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
                .accessibilityIdentifier("today.hrValue")
        } else {
            Text("--")
                .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

/// One metric: label, value, and an optional caption (used once per estimate).
private struct MetricRow: View {
    let title: String
    let value: String
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.weight(.semibold).monospacedDigit())
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
