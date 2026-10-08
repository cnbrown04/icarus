import Testing
@testable import Metrics

@Suite("MinuteAggregation (PLAN.md 8.1)")
struct MinuteAggregationTests {
    @Test func aggregatesMeanMinMaxCountAndCoverage() {
        // Minute 0 holds 60, 62 and 64. Mean = 186 / 3 = 62. Coverage = 3 / 60 = 0.05.
        let samples = [
            HeartRateSample(tsMs: 0, bpm: 60, contact: .detected),
            HeartRateSample(tsMs: 1_000, bpm: 62),
            HeartRateSample(tsMs: 59_999, bpm: 64, contact: .detected),
        ]
        let minutes = MinuteAggregation.aggregate(samples)
        #expect(minutes == [MinuteAggregate(minuteMs: 0, hrAvg: 62, hrMin: 60, hrMax: 64, hrN: 3)])
        #expect(abs(minutes[0].coverage - 0.05) < 1e-12)
    }

    @Test func notDetectedSamplesAreExcluded() {
        // The 200 bpm sample has contact notDetected, so it does not count. Mean stays 62, n stays 3.
        let samples = [
            HeartRateSample(tsMs: 0, bpm: 60, contact: .detected),
            HeartRateSample(tsMs: 1_000, bpm: 62),
            HeartRateSample(tsMs: 2_000, bpm: 200, contact: .notDetected),
            HeartRateSample(tsMs: 3_000, bpm: 64, contact: .detected),
        ]
        let minute = MinuteAggregation.aggregate(samples)[0]
        #expect(minute.hrAvg == 62)
        #expect(minute.hrMax == 64)
        #expect(minute.hrN == 3)
    }

    @Test func minuteBoundaryBelongsToTheLaterMinute() {
        // 59 999 ms is in minute 0. 60 000 ms is the start of minute 60 000.
        let minutes = MinuteAggregation.aggregate([
            HeartRateSample(tsMs: 59_999, bpm: 70),
            HeartRateSample(tsMs: 60_000, bpm: 80),
        ])
        #expect(minutes.map(\.minuteMs) == [0, 60_000])
        #expect(minutes.map(\.hrN) == [1, 1])
    }

    @Test func minuteWithOnlyNotDetectedSamplesIsOmitted() {
        let samples = (0..<60).map { HeartRateSample(tsMs: Int64($0) * 1_000, bpm: 80, contact: .notDetected) }
        #expect(MinuteAggregation.aggregate(samples).isEmpty)
    }

    @Test func outputIsSortedByMinute() {
        let minutes = MinuteAggregation.aggregate([
            HeartRateSample(tsMs: 180_000, bpm: 100),
            HeartRateSample(tsMs: 0, bpm: 60),
        ])
        #expect(minutes.map(\.minuteMs) == [0, 180_000])
    }

    @Test func fortyEightSamplesGiveCoverageOfPointEight() {
        // 48 kept of 60 samples: coverage = 48 / 60 = 0.8, the RHR threshold.
        let samples = (0..<60).map { i in
            HeartRateSample(tsMs: Int64(i) * 1_000, bpm: 70 + i % 7, contact: i < 12 ? .notDetected : .detected)
        }
        let minute = MinuteAggregation.aggregate(samples)[0]
        #expect(minute.hrN == 48)
        #expect(abs(minute.coverage - 0.8) < 1e-12)
    }
}
