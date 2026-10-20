import Charts
import Metrics
import Store
import SwiftUI

/// Heart-rate zones over a day as one horizontal band per zone, in the style of the sleep-stage chart:
/// each contiguous `HRZoneRun` is drawn at its zone's lane, so the day reads as a stack of coloured
/// periods rather than six separate series. Gaps mean minutes without heart rate.
struct ZoneTimelineChart: View {
    let timeline: HRZoneTimeline
    /// Window start, normally local 00:00.
    let fromMs: Int64
    /// Window end, normally now.
    let toMs: Int64

    private static let zones: [HeartRateZone] = [.below, .zone1, .zone2, .zone3, .zone4, .zone5]
    private static let laneHalfHeight = 0.36

    private var xDomain: ClosedRange<Date> {
        let start = min(fromMs, toMs)
        let end = max(toMs, start + LocalTime.msPerMinute)
        return Date(epochMs: start)...Date(epochMs: end)
    }

    /// Minutes per zone, lowest first, for the VoiceOver summary.
    private var zoneMinutes: [(zone: HeartRateZone, minutes: Int)] {
        Self.zones.compactMap { zone in
            let minutes = timeline.runs
                .filter { $0.zone == zone }
                .reduce(0) { $0 + $1.durationMinutes }
            return minutes > 0 ? (zone, minutes) : nil
        }
    }

    private var accessibilityLabelText: String {
        guard let top = zoneMinutes.max(by: { $0.minutes < $1.minutes }) else {
            return "Zone timeline, no data"
        }
        return "Zone timeline, \(Format.duration(minutes: top.minutes)) in \(Self.zoneName(top.zone))"
    }

    private var accessibilityValueText: String {
        guard !zoneMinutes.isEmpty else { return "No zone minutes" }
        return zoneMinutes
            .map { "\(Self.zoneName($0.zone)): \(Format.duration(minutes: $0.minutes))" }
            .joined(separator: ", ")
    }

    var body: some View {
        Chart {
            ForEach(timeline.runs) { run in
                RectangleMark(
                    xStart: .value("Start", Date(epochMs: run.fromMs)),
                    xEnd: .value("End", Date(epochMs: run.toMs)),
                    yStart: .value("Zone", Self.lane(run.zone) - Self.laneHalfHeight),
                    yEnd: .value("Zone", Self.lane(run.zone) + Self.laneHalfHeight)
                )
                .foregroundStyle(Palette.zone(run.zone))
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: -0.5...5.5)
        .chartYAxis {
            AxisMarks(position: .leading, values: (0...5).map { Double($0) }) { value in
                AxisValueLabel {
                    if let lane = value.as(Double.self) {
                        let index = Int(lane.rounded())
                        if Self.zones.indices.contains(index) {
                            Text(Self.shortName(Self.zones[index]))
                                .font(.caption2)
                        }
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 3)) {
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .chartLegend(.hidden)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityValue(accessibilityValueText)
    }

    private static func lane(_ zone: HeartRateZone) -> Double {
        Double(zones.firstIndex(of: zone) ?? 0)
    }

    private static func shortName(_ zone: HeartRateZone) -> String {
        switch zone {
        case .below: "Below"
        case .zone1: "Z1"
        case .zone2: "Z2"
        case .zone3: "Z3"
        case .zone4: "Z4"
        case .zone5: "Z5"
        }
    }

    private static func zoneName(_ zone: HeartRateZone) -> String {
        switch zone {
        case .below: "below zone 1"
        case .zone1: "zone 1"
        case .zone2: "zone 2"
        case .zone3: "zone 3"
        case .zone4: "zone 4"
        case .zone5: "zone 5"
        }
    }
}
