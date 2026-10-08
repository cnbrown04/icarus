import Charts
import SwiftUI

struct HeartRateSparkline: View {
    let samples: [LiveState.Sample]

    var body: some View {
        Chart(samples) { sample in
            LineMark(
                x: .value("Time", sample.date),
                y: .value("Heart rate", sample.bpm)
            )
        }
        .chartYScale(domain: 50 ... 80)
        .chartXAxis(.hidden)
        .accessibilityLabel("Heart rate, last 15 minutes")
    }
}
