import Charts
import SwiftUI

/// Resting and active kcal for each hour of the day, stacked, with the chart's own legend (IOS_UI_SPEC, Charts).
struct HourlyCaloriesChart: View {
    let hours: [Dashboard.CaloriesSnapshot.Hour]

    var body: some View {
        Chart(hours) { hour in
            BarMark(x: .value("Hour", hour.id), y: .value("kcal", hour.resting))
                .foregroundStyle(by: .value("Type", "Resting"))
            BarMark(x: .value("Hour", hour.id), y: .value("kcal", hour.active))
                .foregroundStyle(by: .value("Type", "Active"))
        }
        .chartForegroundStyleScale([
            "Resting": Palette.caloriesResting,
            "Active": Palette.caloriesActive,
        ])
        .chartLegend(position: .bottom, alignment: .leading)
        .chartYAxis {
            AxisMarks(position: .leading)
        }
        .accessibilityLabel("Calories by hour, today")
    }
}
