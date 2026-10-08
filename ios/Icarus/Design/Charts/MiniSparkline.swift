import Charts
import SwiftUI

/// A line with a faint area and no axes, for tiles (IOS_UI_SPEC, Charts).
struct MiniSparkline: View {
    let points: [DayPoint]
    var tint: Color

    var body: some View {
        let range = ChartDomain.sparkline(points.map(\.value))
        Chart(points) { point in
            AreaMark(
                x: .value("Day", point.date),
                yStart: .value("Lower bound", range.lowerBound),
                yEnd: .value("Value", point.value)
            )
            .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    LinearGradient(
                        colors: [tint.opacity(0.3), tint.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            LineMark(x: .value("Day", point.date), y: .value("Value", point.value))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(tint)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: range)
    }
}
