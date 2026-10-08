import Foundation
import Metrics
import Testing
@testable import Icarus

struct StressBucketTests {
    @Test func averagesEachFifteenMinuteBucketAndBandsIt() {
        let fifteen: Int64 = 15 * 60_000
        let buckets = StressBuckets.make(
            [(ms: 0, value: 10), (ms: 60_000, value: 20), (ms: fifteen - 1, value: 30), (ms: fifteen, value: 80)],
            bucketMs: fifteen
        )
        #expect(buckets.count == 2)
        #expect(buckets[0].average == 20)
        #expect(buckets[0].band == .low)
        #expect(buckets[1].average == 80)
        #expect(buckets[1].band == .high)
    }

    @Test func noSamplesMeansNoBuckets() {
        #expect(StressBuckets.make([], bucketMs: 900_000).isEmpty)
    }
}

struct TrendSeriesTests {
    private func point(_ day: Int, _ value: Double) -> DayPoint {
        DayPoint(date: Date(timeIntervalSince1970: Double(day) * 86_400), value: value)
    }

    @Test func comparesTheCurrentAverageWithThePreviousOne() {
        let series = TrendSeries(points: [point(1, 50), point(2, 54)], previousValues: [60, 62])
        #expect(series.average == 52)
        #expect(series.previousAverage == 61)
        #expect(series.change == -9)
        #expect(series.latest == 54)
    }

    @Test func noChangeWithoutAPreviousPeriod() {
        let series = TrendSeries(points: [point(1, 50)], previousValues: [])
        #expect(series.previousAverage == nil)
        #expect(series.change == nil)
    }

    @Test func emptySeriesHasNoAverage() {
        #expect(TrendSeries.empty.average == nil)
        #expect(TrendSeries.empty.latest == nil)
    }
}

struct FormatTests {
    @Test func roundsNumbersBeforeTheUnit() {
        #expect(Format.number(41.6, unit: "bpm") == "42 bpm")
        #expect(Format.number(41.4, unit: "") == "41")
    }

    @Test func picksTheNearestBatterySymbol() {
        #expect(Format.batterySymbol(5) == "battery.0percent")
        #expect(Format.batterySymbol(80) == "battery.75percent")
        #expect(Format.batterySymbol(100) == "battery.100percent")
    }

    @Test func namesStressBands() {
        #expect(Format.stressBand(20) == "Low")
        #expect(Format.stressBand(50) == "Moderate")
        #expect(Format.stressBand(90) == "High")
    }
}

struct HRPointAveragingTests {
    @Test func averagesEachBucketAndKeepsOrder() {
        let points = [60.0, 62, 64, 70, 72].enumerated().map { index, bpm in
            HRPoint(date: Date(timeIntervalSince1970: 1_000 + Double(index) * 6), bpm: bpm)
        }
        // 15 s buckets start at multiples of 15: 990 holds 1000; 1005 holds 1006, 1012, 1018; 1020 holds 1024.
        let averaged = HRPoint.averaged(points, bucket: 15)
        #expect(averaged.map(\.bpm) == [60, (62.0 + 64 + 70) / 3, 72])
        #expect(averaged.map(\.date.timeIntervalSince1970) == [990, 1005, 1020])
    }

    @Test func emptyInputStaysEmpty() {
        #expect(HRPoint.averaged([], bucket: 15).isEmpty)
    }
}
