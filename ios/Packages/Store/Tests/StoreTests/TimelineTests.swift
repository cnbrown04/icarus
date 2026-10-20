import Foundation
import Metrics
import Testing
@testable import Store

struct HRZoneTimelineTests {
    @Test func pointsMapZonesAndRunsCoalesceAdjacentMinutes() {
        let rows = [
            minuteRow(0, hr: 60),        // HRR 0.04, below
            minuteRow(60_000, hr: 60),   // adjacent, below
            minuteRow(120_000, hr: 138), // HRR 0.65, zone 2
            minuteRow(180_000, hr: 138), // adjacent, zone 2
            minuteRow(300_000, hr: 138), // gap at 240k, so a new run
            minuteRow(360_000, hr: nil), // skipped
            minuteRow(420_000, hr: 175), // HRR 0.94, zone 5
        ]
        let timeline = HeartRateSeries.zoneTimeline(rows, restingHR: 55, maxHR: 183)

        #expect(timeline.points.map(\.minuteMs) == [0, 60_000, 120_000, 180_000, 300_000, 420_000])
        #expect(timeline.points.map(\.bpm) == [60, 60, 138, 138, 138, 175])
        #expect(timeline.points.map(\.zone) == [.below, .below, .zone2, .zone2, .zone2, .zone5])
        #expect(timeline.runs == [
            HRZoneRun(fromMs: 0, toMs: 120_000, zone: .below),
            HRZoneRun(fromMs: 120_000, toMs: 240_000, zone: .zone2),
            HRZoneRun(fromMs: 300_000, toMs: 360_000, zone: .zone2),
            HRZoneRun(fromMs: 420_000, toMs: 480_000, zone: .zone5),
        ])
        #expect(timeline.runs.map(\.durationMinutes) == [2, 2, 1, 1])
    }

    @Test func runsSplitWhenTheZoneChanges() {
        let rows = [
            minuteRow(0, hr: 60),       // below
            minuteRow(60_000, hr: 120), // HRR 0.51, zone 1
            minuteRow(120_000, hr: 60), // below
        ]
        let timeline = HeartRateSeries.zoneTimeline(rows, restingHR: 55, maxHR: 183)
        #expect(timeline.runs.map(\.zone) == [.below, .zone1, .below])
        #expect(timeline.runs.map(\.fromMs) == [0, 60_000, 120_000])
    }

    @Test func rowsMayArriveOutOfOrder() {
        let rows = [minuteRow(60_000, hr: 60), minuteRow(0, hr: 60)]
        let timeline = HeartRateSeries.zoneTimeline(rows, restingHR: 55, maxHR: 183)
        #expect(timeline.points.map(\.minuteMs) == [0, 60_000])
        #expect(timeline.runs == [HRZoneRun(fromMs: 0, toMs: 120_000, zone: .below)])
    }

    @Test func noPositiveReserveYieldsAnEmptyTimeline() {
        #expect(HeartRateSeries.zoneTimeline([minuteRow(0)], restingHR: 90, maxHR: 90) == .empty)
        #expect(HeartRateSeries.zoneTimeline([minuteRow(0)], restingHR: 100, maxHR: 90) == .empty)
    }

    @Test func minutesWithoutHeartRateAreLeftOut() {
        let timeline = HeartRateSeries.zoneTimeline([minuteRow(0, hr: nil)], restingHR: 55, maxHR: 183)
        #expect(timeline == .empty)
    }
}

struct StressTimelineTests {
    @Test func pointsKeepEveryMinuteAndSortByTime() {
        var calibrating = minuteRow(120_000, stress: nil)
        calibrating.stressState = StressState.calibrating.rawValue
        let rows = [
            minuteRow(60_000, stress: 20),
            calibrating,
            minuteRow(0, stress: 80),
        ]
        let points = StressTimeline.points(rows)

        #expect(points.map(\.minuteMs) == [0, 60_000, 120_000])
        #expect(points.map(\.stress) == [80, 20, nil])
        #expect(points.map(\.state) == [.value, .value, .calibrating])
        #expect(points.map(\.band) == [.high, .low, nil])
    }

    @Test func hrOnlyMinutesKeepTheirValue() throws {
        var row = minuteRow(0, stress: 55)
        row.stressState = StressState.hrOnly.rawValue
        let point = try #require(StressTimeline.points([row]).first)
        #expect(point.stress == 55)
        #expect(point.state == .hrOnly)
        #expect(point.band == .moderate)
    }
}

struct StressDaySummaryTests {
    @Test func averagePeakAndBandMinutesComeFromPerMinuteValues() {
        let rows = [
            minuteRow(0, stress: 10),
            minuteRow(60_000, stress: 20),
            minuteRow(120_000, stress: 40),
            minuteRow(180_000, stress: 70),
            minuteRow(240_000, stress: nil),
        ]
        let summary = StressDaySummary.make(rows)

        #expect(summary.average == 35)
        #expect(summary.peak == 70)
        #expect(summary.sampleMinutes == 4)
        #expect(summary.minutes(in: .low) == 2)
        #expect(summary.minutes(in: .moderate) == 1)
        #expect(summary.minutes(in: .high) == 1)
        #expect(summary.bandMinutes.map(\.band) == [.low, .moderate, .high])
    }

    @Test func emptyDayHasNoNumbersButAllBands() {
        let summary = StressDaySummary.make([minuteRow(0, stress: nil)])
        #expect(summary.average == nil)
        #expect(summary.peak == nil)
        #expect(summary.sampleMinutes == 0)
        #expect(summary.bandMinutes.map(\.minutes) == [0, 0, 0])
    }

    @Test func samplesVariantUsesTheSameRules() {
        let summary = StressDaySummary.make(samples: [(ms: 0, value: 33), (ms: 60_000, value: 34)])
        #expect(summary.minutes(in: .low) == 1)
        #expect(summary.minutes(in: .moderate) == 1)
    }
}
