import Charts
import SwiftUI

/// Seven, 30 or 90 days of resting HR, nightly RMSSD, stress and calories (PLAN.md §14 row 11).
struct TrendsView: View {
    let environment: AppEnvironment

    @State private var span: TrendSpan = .week
    @State private var snapshot: Dashboard.TrendsSnapshot?

    enum TrendSpan: Int, CaseIterable, Identifiable {
        case week = 7
        case month = 30
        case quarter = 90

        var id: Int { rawValue }

        var label: String {
            switch self {
            case .week: "7 d"
            case .month: "30 d"
            case .quarter: "90 d"
            }
        }
    }

    var body: some View {
        List {
            Section {
                Picker("Span", selection: $span) {
                    ForEach(TrendSpan.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                trendChart(points: restingPoints) {
                    LineMark(x: .value("Day", $0.date), y: .value("Resting HR", $0.value))
                }
            } header: {
                Text("Resting HR")
            } footer: {
                Text(latestText(restingPoints, format: Format.bpm))
            }

            Section {
                trendChart(points: rmssdPoints) {
                    LineMark(x: .value("Day", $0.date), y: .value("RMSSD", $0.value))
                }
            } header: {
                Text("Nightly RMSSD")
            } footer: {
                Text(latestText(rmssdPoints, format: Format.ms))
            }

            Section {
                trendChart(points: stressPoints) {
                    BarMark(x: .value("Day", $0.date), y: .value("Stress", $0.value))
                }
            } header: {
                Text("Stress average")
            } footer: {
                Text(latestText(stressPoints, format: { "\(Int($0.rounded()))" }))
            }

            Section {
                trendChart(points: kcalPoints) {
                    BarMark(x: .value("Day", $0.date), y: .value("kcal", $0.value))
                }
            } header: {
                Text("Calories")
            } footer: {
                Text("Estimated. " + latestText(kcalPoints, format: Format.kcal))
            }
        }
        .navigationTitle("Trends")
        .task(id: span) {
            let days = span.rawValue
            for await value in environment.snapshots(every: .seconds(60), { db, nowMs in
                try Dashboard.trends(db, nowMs: nowMs, dayCount: days)
            }) {
                snapshot = value
            }
        }
    }

    private struct Point: Identifiable {
        let id: Date
        let date: Date
        let value: Double
    }

    private var restingPoints: [Point] {
        points(\.restingHR)
    }

    private var rmssdPoints: [Point] {
        points(\.rmssdNight)
    }

    private var stressPoints: [Point] {
        points(\.stressAverage)
    }

    private var kcalPoints: [Point] {
        points(\.kcalTotal)
    }

    private func points(_ value: KeyPath<DaySummary, Double?>) -> [Point] {
        guard let days = snapshot?.days else { return [] }
        return days.compactMap { summary in
            guard let number = summary[keyPath: value] else { return nil }
            let date = Date(epochMs: Self.dayStart(summary.day, in: snapshot?.context.timeZone))
            return Point(id: date, date: date, value: number)
        }
    }

    private static func dayStart(_ day: LocalDay, in zone: TimeZone?) -> Int64 {
        LocalTime.localTime(day, hour: 12, in: zone ?? Dashboard.fallbackZone)
    }

    @ViewBuilder
    private func trendChart<Marks: ChartContent>(
        points: [Point],
        @ChartContentBuilder marks: @escaping (Point) -> Marks
    ) -> some View {
        if points.isEmpty {
            Text("No data for this span")
                .foregroundStyle(.secondary)
        } else {
            Chart(points) { point in
                marks(point)
            }
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            .frame(height: Spacing.s48 * 3)
        }
    }

    private func latestText(_ points: [Point], format: (Double) -> String) -> String {
        guard let latest = points.last else { return "No data" }
        return "Latest \(format(latest.value))"
    }
}
