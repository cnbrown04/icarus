import Charts
import SwiftUI

/// Daily values as a line, with the period average as a dashed rule (Trends, Resting HR, RMSSD).
struct DayLineChart: View {
    let points: [DayPoint]
    var tint: Color
    var average: Double?

    var body: some View {
        Chart {
            ForEach(points) { point in
                LineMark(x: .value("Day", point.date), y: .value("Value", point.value))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(tint)
                PointMark(x: .value("Day", point.date), y: .value("Value", point.value))
                    .foregroundStyle(tint)
                    .symbolSize(Spacing.s16)
            }
            if let average {
                RuleMark(y: .value("Average", average))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
        }
        .chartYScale(domain: ChartDomain.line(points.map(\.value)))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3))
        }
    }
}

/// Daily values as bars, each coloured by `color` (Trends stress and calories, Stress 7-day bars).
struct DayBarChart: View {
    let points: [DayPoint]
    var color: (Double) -> Color
    var average: Double?

    var body: some View {
        Chart {
            ForEach(points) { point in
                BarMark(x: .value("Day", point.date), y: .value("Value", point.value))
                    .foregroundStyle(color(point.value))
            }
            if let average {
                RuleMark(y: .value("Average", average))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading)
        }
    }
}
