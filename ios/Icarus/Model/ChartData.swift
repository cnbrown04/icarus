import Foundation
import Metrics
import Store

/// One day in a trend, placed at local noon.
struct DayPoint: Identifiable, Equatable, Sendable {
    let date: Date
    let value: Double

    var id: Date { date }
}

/// One heart-rate point for a line chart.
struct HRPoint: Identifiable, Equatable, Sendable {
    let date: Date
    let bpm: Double

    var id: Date { date }

    /// Mean bpm per fixed time bucket. Raw 1 Hz integer samples draw as a noisy band; buckets read as a line.
    static func averaged(_ points: [HRPoint], bucket seconds: TimeInterval) -> [HRPoint] {
        guard seconds > 0 else { return points }
        var groups: [Int64: (sum: Double, count: Int)] = [:]
        for point in points {
            let key = Int64((point.date.timeIntervalSince1970 / seconds).rounded(.down))
            groups[key, default: (0, 0)].sum += point.bpm
            groups[key, default: (0, 0)].count += 1
        }
        return groups.keys.sorted().map { key in
            let group = groups[key]!
            return HRPoint(date: Date(timeIntervalSince1970: Double(key) * seconds), bpm: group.sum / Double(group.count))
        }
    }
}

/// Average stress over one bucket, with its band.
struct StressBucket: Identifiable, Equatable, Sendable {
    let start: Date
    let average: Int

    var band: StressBand { StressBand.of(stress: average) }
    var id: Date { start }
}

enum StressBuckets {
    /// Groups stress values into buckets aligned to `bucketMs`. Each bucket shows the rounded mean.
    static func make(_ samples: [(ms: Int64, value: Int)], bucketMs: Int64) -> [StressBucket] {
        var grouped: [Int64: [Int]] = [:]
        for sample in samples {
            grouped[LocalTime.roundDown(sample.ms, to: bucketMs), default: []].append(sample.value)
        }
        return grouped.keys.sorted().map { start in
            let values = grouped[start, default: []]
            let mean = Double(values.reduce(0, +)) / Double(values.count)
            return StressBucket(start: Date(epochMs: start), average: Int(mean.rounded()))
        }
    }
}

/// A daily series split into the current period and the period before it, for Trends and the Today tiles.
struct TrendSeries: Equatable, Sendable {
    /// Current period, oldest first. Days without a value are left out.
    let points: [DayPoint]
    let average: Double?
    let previousAverage: Double?

    var latest: Double? { points.last?.value }

    /// Current average minus previous average, when both exist.
    var change: Double? {
        guard let average, let previousAverage else { return nil }
        return average - previousAverage
    }

    init(points: [DayPoint], previousValues: [Double]) {
        self.points = points
        average = Self.mean(points.map(\.value))
        previousAverage = Self.mean(previousValues)
    }

    static let empty = TrendSeries(points: [], previousValues: [])

    /// `days` is oldest first. The last `currentCount` days are the current period; the rest are the previous one.
    static func make(
        days: [DaySummary],
        timeZone: TimeZone,
        value: KeyPath<DaySummary, Double?>,
        currentCount: Int
    ) -> TrendSeries {
        let split = max(0, days.count - currentCount)
        let previous = days[..<split].compactMap { $0[keyPath: value] }
        let points = days[split...].compactMap { day -> DayPoint? in
            guard let number = day[keyPath: value] else { return nil }
            return DayPoint(date: Date(epochMs: LocalTime.localTime(day.day, hour: 12, in: timeZone)), value: number)
        }
        return TrendSeries(points: points, previousValues: previous)
    }

    static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}
