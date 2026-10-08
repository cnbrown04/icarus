import Foundation
import Metrics

/// Per-day numbers for Trends and Calories. Derived from `minute_metric`, not stored (PLAN.md 10.3).
public struct DaySummary: Sendable, Equatable {
    public let day: LocalDay
    /// Lowest 5-minute HR in the night of this day (PLAN.md 8.1).
    public let restingHR: Double?
    /// Mean HR weighted by sample count.
    public let hrAvg: Double?
    public let hrMax: Int?
    /// Median RMSSD of the valid 5-minute windows that start between 00:00 and 06:00.
    public let rmssdNight: Double?
    public let stressAverage: Double?
    public let kcalTotal: Double?
    public let kcalActive: Double?
    /// Fraction of the 1440 minutes that have heart-rate samples.
    public let coverage: Double
}

public enum DailyRollup {
    /// Distinct days in ascending order. `LocalDay` is not `Comparable`, so the key is built by hand.
    public static func sortedUnique(_ days: [LocalDay]) -> [LocalDay] {
        Array(Set(days)).sorted { ($0.year, $0.month, $0.day) < ($1.year, $1.month, $1.day) }
    }

    /// `days` may be in any order. The output follows the sorted order of `days`.
    public static func summaries(days: [LocalDay], minutes: [MinuteMetricRow], in timeZone: TimeZone) -> [DaySummary] {
        let sorted = sortedUnique(days)
        let starts = sorted.map { LocalTime.localTime($0, hour: 0, in: timeZone) }
        var buckets = Array(repeating: [MinuteMetricRow](), count: sorted.count)
        for row in minutes {
            guard let index = bucketIndex(for: row.minuteMs, starts: starts) else { continue }
            buckets[index].append(row)
        }
        return sorted.indices.map { index in
            summarize(day: sorted[index], rows: buckets[index], in: timeZone)
        }
    }

    private static func bucketIndex(for ms: Int64, starts: [Int64]) -> Int? {
        var low = 0
        var high = starts.count - 1
        var found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if starts[mid] <= ms {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        // Each day runs until the next day's start, so the match must lie inside the day.
        guard let index = found else { return nil }
        let end = index + 1 < starts.count ? starts[index + 1] : Int64.max
        return ms < end ? index : nil
    }

    private static func summarize(day: LocalDay, rows: [MinuteMetricRow], in timeZone: TimeZone) -> DaySummary {
        let withHR = rows.filter { $0.hrAvg != nil }
        let sampleCount = withHR.reduce(0) { $0 + $1.hrN }
        let hrAvg: Double? = sampleCount > 0
            ? withHR.reduce(0.0) { $0 + ($1.hrAvg ?? 0) * Double($1.hrN) } / Double(sampleCount)
            : nil
        let stresses = rows.compactMap(\.stress).map(Double.init)
        let night = LocalTime.nightWindow(of: day, in: timeZone)
        let nightRMSSD = rows
            .filter { night.contains($0.minuteMs) && $0.minuteMs % LocalTime.msPerWindow == 0 }
            .compactMap(\.rmssdMs)
        return DaySummary(
            day: day,
            restingHR: RestingHR.lowestWindowMean(withHR.compactMap(\.minuteAggregate), in: night),
            hrAvg: hrAvg,
            hrMax: withHR.compactMap(\.hrMax).max(),
            rmssdNight: median(nightRMSSD),
            stressAverage: stresses.isEmpty ? nil : stresses.reduce(0, +) / Double(stresses.count),
            kcalTotal: rows.isEmpty ? nil : rows.reduce(0) { $0 + $1.kcal },
            kcalActive: rows.isEmpty ? nil : rows.reduce(0) { $0 + $1.activeKcal },
            coverage: Double(withHR.count) / 1440
        )
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}

/// One bucket of a heart-rate chart.
public struct HeartRateBucket: Sendable, Equatable {
    public let startMs: Int64
    public let min: Int
    public let avg: Double
    public let max: Int
    public let sampleCount: Int
}

/// One Karvonen zone and the minutes spent in it.
public struct ZoneMinutes: Sendable, Equatable {
    public let zone: HeartRateZone
    public let minutes: Int
}

public enum HeartRateSeries {
    /// Groups minute rows into buckets aligned to `bucketMs`. Minutes without samples are skipped.
    /// The mean is weighted by sample count.
    public static func buckets(_ minutes: [MinuteMetricRow], bucketMs: Int64) -> [HeartRateBucket] {
        var grouped: [Int64: [MinuteMetricRow]] = [:]
        for row in minutes where row.hrAvg != nil {
            grouped[LocalTime.roundDown(row.minuteMs, to: bucketMs), default: []].append(row)
        }
        return grouped.keys.sorted().map { start in
            let rows = grouped[start]!
            let count = rows.reduce(0) { $0 + $1.hrN }
            let sum = rows.reduce(0.0) { $0 + ($1.hrAvg ?? 0) * Double($1.hrN) }
            return HeartRateBucket(
                startMs: start,
                min: rows.compactMap(\.hrMin).min() ?? 0,
                avg: count > 0 ? sum / Double(count) : 0,
                max: rows.compactMap(\.hrMax).max() ?? 0,
                sampleCount: count
            )
        }
    }

    /// Minutes in each zone, lowest zone first. Zones use HRR% against `restingHR` and `maxHR` (PLAN.md 8.1).
    /// Returns nothing when the reserve is not positive.
    public static func zoneMinutes(_ minutes: [MinuteMetricRow], restingHR: Double, maxHR: Double) -> [ZoneMinutes] {
        let order: [HeartRateZone] = [.below, .zone1, .zone2, .zone3, .zone4, .zone5]
        guard maxHR > restingHR else { return [] }
        var counts = Array(repeating: 0, count: order.count)
        for row in minutes {
            guard let hr = row.hrAvg,
                  let fraction = HeartRateZones.hrrFraction(hr: hr, restingHR: restingHR, maxHR: maxHR)
            else { continue }
            let zone = HeartRateZone.of(hrrFraction: fraction)
            if let index = order.firstIndex(of: zone) {
                counts[index] += 1
            }
        }
        return zip(order, counts).map { ZoneMinutes(zone: $0, minutes: $1) }
    }
}
