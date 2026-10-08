import Charts
import SwiftUI

/// The last 15 minutes of raw samples (PLAN.md §14 row 7). Axes are hidden; the value is shown above it.
struct HeartRateSparkline: View {
    let points: [Dashboard.TodaySnapshot.Point]

    var body: some View {
        Chart(points) { point in
            LineMark(
                x: .value("Time", point.date),
                y: .value("Heart rate", point.bpm)
            )
        }
        .chartXAxis(.hidden)
        .accessibilityLabel("Heart rate, last 15 minutes")
    }
}
