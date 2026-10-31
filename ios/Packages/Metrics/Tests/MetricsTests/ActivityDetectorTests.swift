import Testing
@testable import Metrics

/// Synthetic minute traces for the activity heuristic. Resting HR 60 and HRmax 190 give a reserve of 130 and a
/// zone-1 threshold of 125 bpm, so 150 bpm is an activity minute and 60 bpm is not.
@Suite("ActivityDetector: auto-detected bouts from minute HR (our heuristic)")
struct ActivityDetectorTests {
    private let minute = LocalTime.msPerMinute
    private let restingHR = 60.0
    private let maxHR = 190.0
    private var threshold: Double { ActivityDetector.thresholdBPM(restingHR: restingHR, maxHR: maxHR) ?? .nan }
    private let origin: Int64 = 1_791_383_400_000

    /// One aggregate per minute. `pattern` gives the bpm for each minute, starting at `origin`.
    private func trace(_ pattern: [(bpm: Double, minutes: Int)]) -> [MinuteAggregate] {
        var out: [MinuteAggregate] = []
        var index = 0
        for segment in pattern {
            for _ in 0..<segment.minutes {
                out.append(MinuteAggregate(
                    minuteMs: origin + Int64(index) * minute,
                    hrAvg: segment.bpm,
                    hrMin: Int(segment.bpm),
                    hrMax: Int(segment.bpm),
                    hrN: 60
                ))
                index += 1
            }
        }
        return out
    }

    private func detect(_ minutes: [MinuteAggregate], sleep: [Range<Int64>] = []) -> [ActivityBout] {
        ActivityDetector.detect(minutes, thresholdBPM: threshold, sleep: sleep)
    }

    private func minuteOffset(_ minutes: Int) -> Int64 {
        origin + Int64(minutes) * minute
    }

    // MARK: - Threshold

    @Test func thresholdIsTheZoneOneLowerBound() throws {
        #expect(abs(threshold - 125) < 1e-9)
        // The threshold sits in zone 1 and one bpm below it does not, per HeartRateZone's boundaries.
        let atThreshold = try #require(HeartRateZones.hrrFraction(hr: threshold, restingHR: restingHR, maxHR: maxHR))
        let below = try #require(HeartRateZones.hrrFraction(hr: threshold - 1, restingHR: restingHR, maxHR: maxHR))
        #expect(HeartRateZone.of(hrrFraction: atThreshold) == .zone1)
        #expect(HeartRateZone.of(hrrFraction: below) == .below)
    }

    @Test func thresholdIsNilWithoutAReserve() {
        #expect(ActivityDetector.thresholdBPM(restingHR: 190, maxHR: 190) == nil)
    }

    // MARK: - Detection

    @Test func detectsA40MinuteRun() {
        let minutes = trace([(60, 10), (150, 40), (60, 10)])
        let bouts = detect(minutes)
        #expect(bouts == [ActivityBout(startMs: minuteOffset(10), endMs: minuteOffset(50))])
        #expect(bouts.first?.durationMinutes == 40)
    }

    @Test func dropsA10MinuteWalk() {
        let minutes = trace([(60, 10), (130, 10), (60, 30)])
        #expect(detect(minutes).isEmpty)
    }

    @Test func keepsA15MinuteBoutAndDropsA14MinuteOne() {
        #expect(detect(trace([(150, 15)])).count == 1)
        #expect(detect(trace([(150, 14)])).isEmpty)
    }

    @Test func needsThreeConsecutiveActiveMinutesToStart() {
        // Two active minutes, then a dip, then a 15-minute bout. The stray pair must not extend the bout.
        let minutes = trace([(60, 5), (150, 2), (60, 1), (150, 15), (60, 5)])
        let bouts = detect(minutes)
        #expect(bouts == [ActivityBout(startMs: minuteOffset(8), endMs: minuteOffset(23))])
    }

    @Test func mergesTwoBoutsAcrossA3MinuteGap() {
        // 20 min, 3 min below, 20 min: the dip is shorter than 5 minutes, so one bout of 43 minutes.
        let minutes = trace([(150, 20), (60, 3), (150, 20)])
        let bouts = detect(minutes)
        #expect(bouts == [ActivityBout(startMs: minuteOffset(0), endMs: minuteOffset(43))])
    }

    @Test func mergesBoutsAcrossA5MinuteGap() {
        // A 5-minute dip ends the first candidate, and the gap is still at most 5 minutes, so they merge.
        let minutes = trace([(150, 20), (60, 5), (150, 20)])
        #expect(detect(minutes) == [ActivityBout(startMs: minuteOffset(0), endMs: minuteOffset(45))])
    }

    @Test func keepsBoutsSeparatedByA6MinuteGapApart() {
        let minutes = trace([(150, 20), (60, 6), (150, 20)])
        #expect(detect(minutes).count == 2)
    }

    @Test func clipsABoutOverlappingSleepAndKeepsOnlyTheAwakePart() {
        // A 40-minute bout whose first 20 minutes are inside a sleep window. Only the last 20 minutes remain.
        let minutes = trace([(150, 40), (60, 10)])
        let sleep = [minuteOffset(0)..<minuteOffset(20)]
        #expect(detect(minutes, sleep: sleep) == [ActivityBout(startMs: minuteOffset(20), endMs: minuteOffset(40))])
    }

    @Test func aSleepWindowInTheMiddleSplitsTheBoutIntoShortPieces() {
        // Two 10-minute pieces, both under the 15-minute minimum, so nothing is kept.
        let minutes = trace([(150, 30)])
        let sleep = [minuteOffset(10)..<minuteOffset(20)]
        #expect(detect(minutes, sleep: sleep).isEmpty)
    }

    @Test func aBoutNeverMergesAcrossSleep() {
        // Two 20-minute bouts with a 4-minute gap, and a sleep window covering the gap. They stay apart.
        let minutes = trace([(150, 20), (60, 4), (150, 20)])
        let sleep = [minuteOffset(20)..<minuteOffset(24)]
        let bouts = detect(minutes, sleep: sleep)
        #expect(bouts == [
            ActivityBout(startMs: minuteOffset(0), endMs: minuteOffset(20)),
            ActivityBout(startMs: minuteOffset(24), endMs: minuteOffset(44)),
        ])
    }

    @Test func missingMinutesCountAsBelowThreshold() {
        // 20 active minutes, then 6 minutes with no rows at all, then 20 more. The gap is a split.
        var minutes = trace([(150, 20)])
        minutes += (0..<20).map { index in
            MinuteAggregate(minuteMs: minuteOffset(26 + index), hrAvg: 150, hrMin: 150, hrMax: 150, hrN: 60)
        }
        #expect(detect(minutes).count == 2)
    }

    // MARK: - Summary

    @Test func summarisesA40MinuteRun() throws {
        let profile = UserProfile(sex: .male, ageYears: 36, heightCm: 178, weightKg: 80)
        let minutes = trace([(60, 10), (150, 40), (60, 10)])
        let summary = ActivitySummary.make(
            startMs: minuteOffset(10),
            endMs: minuteOffset(50),
            minutes: minutes,
            restingHR: restingHR,
            maxHR: maxHR,
            profile: profile
        )
        #expect(summary.durationMinutes == 40)
        #expect(abs((summary.avgHR ?? 0) - 150) < 1e-9)
        #expect(summary.maxHR == 150)
        // 150 bpm is 69 % HRR: zone 2 (index 2), for all 40 minutes.
        #expect(summary.zoneMinutes.count == 6)
        #expect(abs(summary.zoneMinutes[2] - 40) < 1e-9)
        #expect(summary.zoneMinutes.reduce(0, +) == 40)
        let kcal = try #require(summary.kcal)
        #expect(kcal > 0)
        let strain = try #require(summary.strain)
        #expect(strain > 0 && strain <= Strain.whoopMaxStrain)
    }

    @Test func kcalNeedsAProfileAndStrainNeedsAReserve() {
        let minutes = trace([(150, 20)])
        let noProfile = ActivitySummary.make(
            startMs: minuteOffset(0), endMs: minuteOffset(20), minutes: minutes,
            restingHR: restingHR, maxHR: maxHR, profile: nil
        )
        #expect(noProfile.kcal == nil)
        #expect(noProfile.strain != nil)

        let noReserve = ActivitySummary.make(
            startMs: minuteOffset(0), endMs: minuteOffset(20), minutes: minutes,
            restingHR: 190, maxHR: 190, profile: nil
        )
        #expect(noReserve.strain == nil)
    }

    @Test func summaryCountsOnlyMinutesInsideTheSpan() {
        // The span covers the middle 10 minutes of a 20-minute run at 150 bpm.
        let minutes = trace([(150, 20)])
        let summary = ActivitySummary.make(
            startMs: minuteOffset(5), endMs: minuteOffset(15), minutes: minutes,
            restingHR: restingHR, maxHR: maxHR, profile: nil
        )
        #expect(summary.zoneMinutes.reduce(0, +) == 10)
        #expect(summary.durationMinutes == 10)
    }

    @Test func shortUngatedStrainScoresAFifteenMinuteSpan() {
        // The day gate would refuse 15 minute aggregates (it wants 20 sparse samples). The activity path does not.
        let minutes = trace([(150, 15)])
        #expect(Strain.score(minutes: minutes, restingHR: restingHR, maxHR: maxHR, method: .banister) == nil)
        let score = Strain.scoreActivity(minutes: minutes, restingHR: restingHR, maxHR: maxHR, method: .banister)
        #expect((score?.strain ?? 0) > 0)
    }
}
