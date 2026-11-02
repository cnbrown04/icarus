import Charts
import GRDB
import Metrics
import Store
import SwiftUI

/// Skin temperature, night by night, against the user's own usual. The band's skin sensor (frame 76) has no verified
/// conversion to degrees, so each night is shown as its difference from the median of the nights before it, with the
/// usual range shaded: the same range Vitals judges tonight against. No number carries a unit.
struct SkinTemperatureView: View {
    let environment: AppEnvironment

    @State private var nights: [Night]?
    @State private var aboutExpanded = false

    /// One night: when it ended, and its difference from the prior nights' median (nil while there are too few).
    struct Night: Identifiable, Equatable, Sendable {
        let date: Date
        let deviation: Double
        /// Half the usual range at that night, in the same counts.
        let halfWidth: Double
        var id: Date { date }
    }

    var body: some View {
        List {
            Section {
                header
                chart
                    .frame(height: ChartHeight.detail)
            }
            Section {
                DisclosureGroup("About", isExpanded: $aboutExpanded) {
                    Text("Measured by the band's skin sensor while you sleep, then compared with your own recent nights. The sensor has no verified conversion to degrees, so only higher or lower than usual is shown.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .redacted(reason: nights == nil ? .placeholder : [])
        .navigationTitle("Skin Temperature")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let nowMs = environment.clock.nowMs
            nights = (try? await environment.database.writer.read { db in try Self.load(db, nowMs: nowMs) }) ?? []
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.s4) {
            Text(headline)
                .font(.title3.weight(.semibold))
            Text("Last night against your usual")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, Spacing.s4)
    }

    private var headline: String {
        guard let last = nights?.last else { return "Not enough nights yet" }
        if last.deviation > last.halfWidth { return "Above your usual range" }
        if last.deviation < -last.halfWidth { return "Below your usual range" }
        return "Within your usual range"
    }

    private var chart: some View {
        Chart {
            ForEach(nights ?? []) { night in
                RectangleMark(
                    x: .value("Night", night.date, unit: .day),
                    yStart: .value("Usual low", -night.halfWidth),
                    yEnd: .value("Usual high", night.halfWidth)
                )
                .foregroundStyle(Color.secondary.opacity(0.12))
                PointMark(x: .value("Night", night.date, unit: .day), y: .value("Vs usual", night.deviation))
                    .foregroundStyle(abs(night.deviation) > night.halfWidth ? Palette.warn : MetricCategory.recovery.color)
            }
            RuleMark(y: .value("Usual", 0))
                .foregroundStyle(Color.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [Spacing.s4, Spacing.s4]))
        }
        // Always the last 30 days, so one night still reads as a night on a calendar, not as hours.
        .chartXScale(domain: Date().addingTimeInterval(-30 * 86_400)...Date())
        .chartYAxisLabel("vs usual")
        .metricChartStyle()
        .accessibilityLabel("Skin temperature, each night against your usual")
    }

    /// The last 30 nights with a value, each against the median of up to 30 nights before it (at least
    /// `HealthMonitor.minimumNights`), using the same range rule as Vitals.
    nonisolated static func load(_ db: Database, nowMs: Int64) throws -> [Night] {
        let zone = try Dashboard.Context.load(db, nowMs: nowMs).timeZone
        let today = LocalTime.localDay(containing: nowMs, in: zone)
        let first = LocalTime.adding(days: -(30 + HealthMonitor.baselineNights), to: today)
        let all = try db.skinTemperatureNights(from: first, through: today, in: zone)
        return all.indices.compactMap { index -> Night? in
            let prior = all[..<index].suffix(HealthMonitor.baselineNights).map { $0.value }
            guard let range = HealthMonitor.baseline(for: .skinTemp, nightly: Array(prior)) else { return nil }
            let night = all[index]
            return Night(
                date: Date(epochMs: LocalTime.localTime(night.day, hour: 12, in: zone)),
                deviation: night.value - range.center,
                halfWidth: range.high - range.center
            )
        }
        .suffix(30)
    }
}
