import Foundation
import Metrics

/// One minute of a heart-rate zone timeline. Only minutes with a heart-rate average have a point.
public struct HRZoneMinute: Sendable, Equatable, Identifiable {
    /// Start of the minute, epoch ms UTC.
    public let minuteMs: Int64
    /// Mean bpm for the minute.
    public let bpm: Double
    public let zone: HeartRateZone

    public var id: Int64 { minuteMs }
}

/// A contiguous run of adjacent minutes in the same zone. `toMs` is exclusive: the end of the last minute.
public struct HRZoneRun: Sendable, Equatable, Identifiable {
    public let fromMs: Int64
    public let toMs: Int64
    public let zone: HeartRateZone

    public var id: Int64 { fromMs }
    public var durationMinutes: Int { Int((toMs - fromMs) / LocalTime.msPerMinute) }
}

/// Per-minute points and coalesced runs for a heart-rate zone chart.
public struct HRZoneTimeline: Sendable, Equatable {
    /// Every minute with heart rate, oldest first.
    public let points: [HRZoneMinute]
    /// Adjacent same-zone minutes folded together, oldest first.
    public let runs: [HRZoneRun]

    public static let empty = HRZoneTimeline(points: [], runs: [])
}

public extension HeartRateSeries {
    /// Maps each minute's `hrAvg` through the Karvonen fraction and folds adjacent same-zone minutes
    /// into runs. Minutes are adjacent only when they are exactly one minute apart, so gaps split runs.
    /// Returns an empty timeline when the reserve is not positive, matching `zoneMinutes`.
    static func zoneTimeline(
        _ minutes: [MinuteMetricRow],
        restingHR: Double,
        maxHR: Double
    ) -> HRZoneTimeline {
        guard maxHR > restingHR else { return .empty }

        var points: [HRZoneMinute] = []
        for row in minutes.sorted(by: { $0.minuteMs < $1.minuteMs }) {
            guard let hr = row.hrAvg,
                  let fraction = HeartRateZones.hrrFraction(hr: hr, restingHR: restingHR, maxHR: maxHR)
            else { continue }
            points.append(HRZoneMinute(minuteMs: row.minuteMs, bpm: hr, zone: HeartRateZone.of(hrrFraction: fraction)))
        }

        var runs: [HRZoneRun] = []
        for point in points {
            if let last = runs.last, last.zone == point.zone, last.toMs == point.minuteMs {
                runs[runs.count - 1] = HRZoneRun(
                    fromMs: last.fromMs,
                    toMs: point.minuteMs + LocalTime.msPerMinute,
                    zone: point.zone
                )
            } else {
                runs.append(HRZoneRun(
                    fromMs: point.minuteMs,
                    toMs: point.minuteMs + LocalTime.msPerMinute,
                    zone: point.zone
                ))
            }
        }
        return HRZoneTimeline(points: points, runs: runs)
    }
}

/// One minute of a stress timeline. `stress` is nil for calibrating, exertion and insufficient minutes.
public struct StressTimelinePoint: Sendable, Equatable, Identifiable {
    /// Start of the minute, epoch ms UTC.
    public let minuteMs: Int64
    public let stress: Int?
    public let state: StressState

    public var id: Int64 { minuteMs }

    /// The UI band for a scored minute, or nil when the minute has no value.
    public var band: StressBand? { stress.map(StressBand.of) }
}

public enum StressTimeline {
    /// Every minute row in `rows`, oldest first. Rows without a value stay in the timeline so charts
    /// can show gaps instead of connecting across calibrating or exertion periods.
    public static func points(_ rows: [MinuteMetricRow]) -> [StressTimelinePoint] {
        rows.sorted { $0.minuteMs < $1.minuteMs }.map { row in
            StressTimelinePoint(minuteMs: row.minuteMs, stress: row.stress, state: row.state)
        }
    }
}

/// Minutes in one stress band.
public struct StressBandMinutes: Sendable, Equatable, Identifiable {
    public let band: StressBand
    public let minutes: Int

    public var id: StressBand { band }
}

/// One day's stress numbers, read from the per-minute stress values (the same rows the 15-minute
/// buckets are built from). A sample is one minute.
public struct StressDaySummary: Sendable, Equatable {
    /// Mean stress over minutes that have a value.
    public let average: Double?
    public let peak: Int?
    /// Low, moderate and high, in that order.
    public let bandMinutes: [StressBandMinutes]
    /// Minutes that have a stress value.
    public let sampleMinutes: Int

    public func minutes(in band: StressBand) -> Int {
        bandMinutes.first { $0.band == band }?.minutes ?? 0
    }

    public static func make(samples: [(ms: Int64, value: Int)]) -> StressDaySummary {
        let values = samples.map(\.value)
        guard !values.isEmpty else {
            return StressDaySummary(
                average: nil,
                peak: nil,
                bandMinutes: StressBand.allCases.map { StressBandMinutes(band: $0, minutes: 0) },
                sampleMinutes: 0
            )
        }

        var counts: [StressBand: Int] = [:]
        for value in values {
            counts[StressBand.of(stress: value), default: 0] += 1
        }
        return StressDaySummary(
            average: Double(values.reduce(0, +)) / Double(values.count),
            peak: values.max(),
            bandMinutes: StressBand.allCases.map { StressBandMinutes(band: $0, minutes: counts[$0, default: 0]) },
            sampleMinutes: values.count
        )
    }

    public static func make(_ rows: [MinuteMetricRow]) -> StressDaySummary {
        make(samples: rows.compactMap { row in row.stress.map { (ms: row.minuteMs, value: $0) } })
    }
}
