import SwiftUI

/// Stress on a 0-100 gauge that runs green, yellow, red (IOS_UI_SPEC, Design). Nil shows an empty gauge.
struct StressGauge: View {
    let value: Int?

    var body: some View {
        Gauge(value: Double(value ?? 0), in: 0.0...100.0) {
            Image(systemName: "gauge.with.dots.needle.67percent")
        } currentValueLabel: {
            Text(value.map { "\($0)" } ?? "--")
                .monospacedDigit()
        }
        .gaugeStyle(.accessoryCircular)
        .tint(Gradient(colors: [Palette.stressLow, Palette.stressModerate, Palette.stressHigh]))
        .accessibilityLabel("Stress")
        .accessibilityValue(value.map { "\($0), \(Format.stressBand($0))" } ?? "No value")
    }
}
