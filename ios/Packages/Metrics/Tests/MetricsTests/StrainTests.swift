import Testing
@testable import Metrics

/// Expected values are hand-derived from NOOP's StrainScorer formulas. Edwards: TRIMP = sum of zone
/// weight x minutes. Strain = 100 x ln(TRIMP + 1) / ln(7201), rounded to two decimals. Banister:
/// per-sample duration x max(c x x x e^(bx) - floor, 0), where the floor is 0.64 x 0.10 x e^(0.1 b).
@Suite("Strain: Edwards and Banister TRIMP, log map to 0-100, gates (NOOP StrainScorer)")
struct StrainTests {

    /// `count` samples at `bpm`, one per `stepMs`, starting at `startMs`. The default is 1 Hz.
    private func samples(bpm: Int, count: Int, stepMs: Int64 = 1_000, startMs: Int64 = 0) -> [HeartRateSample] {
        (0..<count).map { HeartRateSample(tsMs: startMs + Int64($0) * stepMs, bpm: bpm) }
    }

    private let restingHR = 60.0
    private let maxHR = 180.0 // Reserve = 120 bpm, so bpm 120 is 50 % HRR and bpm 180 is 100 %.

    // MARK: - Edwards known answers

    @Test func edwardsZoneOneKnownAnswer() throws {
        // 600 samples at 1 Hz = 600 s = 10 min. 120 bpm is 50 % HRR, which is zone 1 (weight 1).
        // TRIMP = 10. Strain = 100 x ln(11) / ln(7201) = 26.997, which is 27.00 to two decimals.
        let score = try #require(Strain.score(samples(bpm: 120, count: 600), restingHR: restingHR, maxHR: maxHR))
        #expect(abs(score.trimp - 10) < 1e-9)
        #expect(abs(score.strain - 27.00) < 0.005)
        #expect(score.method == .edwards)
        #expect(abs(score.zoneMinutes[1] - 10) < 1e-9)
        #expect(score.zoneMinutes[0] == 0)
    }

    @Test func edwardsZoneFiveKnownAnswer() throws {
        // 180 bpm is 100 % HRR, which is zone 5 (weight 5). TRIMP = 5 x 10 = 50.
        // Strain = 100 x ln(51) / ln(7201) = 44.27.
        let score = try #require(Strain.score(samples(bpm: 180, count: 600), restingHR: restingHR, maxHR: maxHR))
        #expect(abs(score.trimp - 50) < 1e-9)
        #expect(abs(score.strain - 44.27) < 0.005)
        #expect(abs(score.zoneMinutes[5] - 10) < 1e-9)
    }

    @Test func edwardsWeightsByZoneAndTime() throws {
        // 300 samples at zone 1 (5 min) and 300 at zone 5 (5 min). TRIMP = 5 x 1 + 5 x 5 = 30.
        // Strain = 100 x ln(31) / ln(7201) = 38.66.
        let mixed = samples(bpm: 120, count: 300) + samples(bpm: 180, count: 300, startMs: 300_000)
        let score = try #require(Strain.score(mixed, restingHR: restingHR, maxHR: maxHR))
        #expect(abs(score.trimp - 30) < 1e-9)
        #expect(abs(score.strain - 38.66) < 0.005)
        #expect(abs(score.zoneMinutes[1] - 5) < 1e-9)
        #expect(abs(score.zoneMinutes[5] - 5) < 1e-9)
    }

    @Test func zoneMinutesSumToCreditedDuration() throws {
        let mixed = samples(bpm: 100, count: 200) + samples(bpm: 150, count: 200, startMs: 200_000)
            + samples(bpm: 175, count: 200, startMs: 400_000)
        let score = try #require(Strain.score(mixed, restingHR: restingHR, maxHR: maxHR))
        #expect(abs(score.zoneMinutes.reduce(0, +) - 600.0 / 60.0) < 1e-9)
    }

    @Test func moreHighZoneTimeMeansMoreStrain() throws {
        // Both days have the same length (10 min). Day B spends more of it in zone 5.
        let lowDay = try #require(Strain.score(samples(bpm: 130, count: 600), restingHR: restingHR, maxHR: maxHR))
        let mixedDay = try #require(Strain.score(
            samples(bpm: 130, count: 300) + samples(bpm: 170, count: 300, startMs: 300_000),
            restingHR: restingHR, maxHR: maxHR))
        let highDay = try #require(Strain.score(samples(bpm: 170, count: 600), restingHR: restingHR, maxHR: maxHR))
        #expect(lowDay.strain < mixedDay.strain)
        #expect(mixedDay.strain < highDay.strain)
    }

    @Test func zoneBoundariesAreInclusiveLowerBounds() throws {
        // 132 bpm is exactly 60 % HRR ((132 - 60) / 120), which is zone 2 (weight 2). It is not zone 1.
        let score = try #require(Strain.score(samples(bpm: 132, count: 600), restingHR: restingHR, maxHR: maxHR))
        #expect(abs(score.zoneMinutes[2] - 10) < 1e-9)
        #expect(score.zoneMinutes[1] == 0)
    }

    // MARK: - Banister known answer

    @Test func banisterKnownAnswerForMen() throws {
        // 120 bpm, x = 0.5. Rate = 0.5 x 0.64 x e^(0.96) = 0.83574.
        // Floor = 0.64 x 0.10 x e^(0.192) = 0.07756. Per minute 0.75818 over 10 min: TRIMP = 7.5820.
        // D = 1440 x 0.64 x e^(1.92) - 1440 x 0.07756 + 1 = 6175.5. Strain = 100 x ln(8.582) / ln(6175.5) = 24.63.
        let score = try #require(Strain.score(samples(bpm: 120, count: 600), restingHR: restingHR, maxHR: maxHR,
                                              method: .banister, sex: .male))
        #expect(score.method == .banister)
        #expect(abs(score.trimp - 7.5820) < 1e-3)
        #expect(abs(score.strain - 24.63) < 0.005)
    }

    @Test func banisterSedentaryFloorRemovesDeskDay() throws {
        // 66 bpm is 5 % HRR, below the 10 % sedentary floor. Rate 0.0352 < floor 0.0776, so it adds nothing.
        // Without the floor a 24 h day at this level would score about 45 (NOOP #1624).
        let score = try #require(Strain.score(samples(bpm: 66, count: 600), restingHR: restingHR, maxHR: maxHR,
                                              method: .banister, sex: .male))
        #expect(score.trimp == 0)
        #expect(score.strain == 0)
    }

    @Test func banisterDenominatorBelongsToTheMethod() {
        // Banister's sex-dependent ceiling is not Edwards' 7201. NOOP #1545.
        #expect(Strain.logMapDenominator(method: .edwards, sex: .male) == 7201)
        #expect(abs(Strain.logMapDenominator(method: .banister, sex: .male) - 6175.5278) < 0.01)
        #expect(abs(Strain.logMapDenominator(method: .banister, sex: .female) - 4787.7834) < 0.01)
    }

    // MARK: - Log map

    @Test func logMapTopIsOneHundredAtItsCeiling() {
        // A theoretical maximum day maps to exactly 100 under each method.
        #expect(abs(Strain.trimpToStrain(7200, denominator: 7201) - 100) < 0.005)
        let banisterCeiling = Strain.logMapDenominator(method: .banister, sex: .male)
        #expect(abs(Strain.trimpToStrain(banisterCeiling - 1, denominator: banisterCeiling) - 100) < 0.005)
    }

    @Test func logMapIsZeroForNoLoadOrOutOfDomainDenominator() {
        #expect(Strain.trimpToStrain(0) == 0)
        #expect(Strain.trimpToStrain(-5) == 0)
        #expect(Strain.trimpToStrain(10, denominator: 1) == 0)
    }

    @Test func logMapIsMonotoneInTRIMP() {
        let values = [1.0, 10.0, 100.0, 1000.0, 7000.0].map { Strain.trimpToStrain($0) }
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 < $1 })
    }

    // MARK: - Gates and edge cases

    @Test func heartRateAtOrBelowRestingScoresZeroNotNil() throws {
        // Enough data, but no time above the reserve floor. Valid zero, not "no data".
        let atRest = try #require(Strain.score(samples(bpm: 60, count: 600), restingHR: restingHR, maxHR: maxHR))
        #expect(atRest.strain == 0)
        #expect(abs(atRest.zoneMinutes[0] - 10) < 1e-9)
        let belowRest = try #require(Strain.score(samples(bpm: 50, count: 600), restingHR: restingHR, maxHR: maxHR))
        #expect(belowRest.strain == 0)
        #expect(belowRest.trimp == 0)
    }

    @Test func maxHRNotAboveRestingHRIsNil() {
        #expect(Strain.score(samples(bpm: 120, count: 600), restingHR: 60, maxHR: 60) == nil)
        #expect(Strain.score(samples(bpm: 120, count: 600), restingHR: 60, maxHR: 55) == nil)
    }

    @Test func emptyInputIsNil() {
        #expect(Strain.score([], restingHR: restingHR, maxHR: maxHR) == nil)
        #expect(Strain.score(minutes: [], restingHR: restingHR, maxHR: maxHR) == nil)
    }

    @Test func sparseStreamNeedsTwentySamplesSpanningTenMinutes() {
        // 19 samples over an hour: too few. 20 samples spanning 500 s: too short a span.
        #expect(Strain.score(samples(bpm: 120, count: 19, stepMs: 3_600_000 / 18),
                             restingHR: restingHR, maxHR: maxHR) == nil)
        #expect(Strain.score(samples(bpm: 120, count: 20, stepMs: 500_000 / 19),
                             restingHR: restingHR, maxHR: maxHR) == nil)
        // 21 samples at 30 s steps span exactly 600 s, which passes the sparse gate.
        #expect(Strain.score(samples(bpm: 120, count: 21, stepMs: 30_000),
                             restingHR: restingHR, maxHR: maxHR) != nil)
    }

    @Test func notDetectedSamplesAreDropped() {
        let dropped = samples(bpm: 180, count: 600).map {
            HeartRateSample(tsMs: $0.tsMs, bpm: $0.bpm, contact: .notDetected)
        }
        #expect(Strain.score(dropped, restingHR: restingHR, maxHR: maxHR) == nil)
    }

    @Test func longDropoutIsClampedToTwoMinutes() throws {
        // 600 dense samples at zone 5, then one sample at zone 0 an hour later.
        // The last dense sample would otherwise be credited the whole hour. Clamped, it gets 2 min.
        // Zone 5 = 599 x (1/60) + 2 = 11.9833 min, so TRIMP = 5 x 11.9833 = 59.9167.
        let dense = samples(bpm: 180, count: 600)
        let later = HeartRateSample(tsMs: 599_000 + 3_600_000, bpm: 60)
        let score = try #require(Strain.score(dense + [later], restingHR: restingHR, maxHR: maxHR))
        #expect(abs(score.zoneMinutes[5] - (599.0 / 60.0 + 2.0)) < 1e-6)
        #expect(abs(score.trimp - 5 * (599.0 / 60.0 + 2.0)) < 1e-6)
        // The final sample reuses the 2-minute clamped gap before it.
        #expect(abs(score.zoneMinutes[0] - 2.0) < 1e-9)
    }

    @Test func inputOrderDoesNotChangeTheScore() throws {
        let forward = samples(bpm: 120, count: 300) + samples(bpm: 180, count: 300, startMs: 300_000)
        let reversed = Array(forward.reversed())
        let a = try #require(Strain.score(forward, restingHR: restingHR, maxHR: maxHR))
        let b = try #require(Strain.score(reversed, restingHR: restingHR, maxHR: maxHR))
        #expect(a == b)
    }

    // MARK: - Minute aggregates

    @Test func minuteAggregatesAreOneMinuteEach() throws {
        // 60 consecutive minutes at 120 bpm (zone 1). TRIMP = 60. Strain = 100 x ln(61) / ln(7201) = 46.28.
        let minutes = (0..<60).map { i in
            MinuteAggregate(minuteMs: Int64(i) * 60_000, hrAvg: 120, hrMin: 120, hrMax: 120, hrN: 60)
        }
        let score = try #require(Strain.score(minutes: minutes, restingHR: restingHR, maxHR: maxHR))
        #expect(abs(score.trimp - 60) < 1e-9)
        #expect(abs(score.strain - 46.28) < 0.005)
    }

    // MARK: - WHOOP 0-21 mapping

    @Test func whoopScaleMapsEndpointsAndInverts() {
        #expect(Strain.effort(fromWhoopStrain: 21) == 100)
        #expect(Strain.effort(fromWhoopStrain: 10.5) == 50)
        #expect(Strain.whoopStrain(fromEffort: 100) == 21)
        #expect(abs(Strain.whoopStrain(fromEffort: Strain.effort(fromWhoopStrain: 13.7)) - 13.7) < 1e-12)
    }
}
