import Testing
@testable import Metrics

/// Expected values are hand-derived from NOOP's RecoveryScorer and Baselines formulas, not read off
/// the implementation. The sigma for a floor-spread baseline is 1.253 x floor, so a score of exactly
/// 0 z needs the tonight value to equal the baseline mean.
@Suite("Recovery: EWMA baselines, z-score composite, logistic score, band (NOOP RecoveryScorer)")
struct RecoveryTests {

    private func repeated(_ value: Double, _ count: Int) -> [Double?] {
        Array(repeating: value, count: count)
    }

    private func scored(_ input: Recovery.Input) -> Recovery.Score? {
        if case .scored(let score) = Recovery.score(input) { return score }
        return nil
    }

    // MARK: - Known answers

    @Test func neutralNightIsFiftyEightPercent() {
        // HRV baseline 50 ms (constant, so spread stays at the floor 5). Resting HR baseline 60 bpm
        // (floor 2). Tonight matches both, so both z-scores are 0. The composite z is 0, and
        // 100 / (1 + e^(-1.6 x 0.2)) = 57.93. That is NOOP's population-mean anchor.
        let input = Recovery.Input(hrv: 50, restingHR: 60,
                                   hrvHistory: repeated(50, 10),
                                   restingHRHistory: repeated(60, 10))
        guard let score = scored(input) else { Issue.record("expected a score"); return }
        #expect(abs(score.score - 57.9324) < 0.001)
        #expect(score.band == .yellow)
        #expect(abs(score.compositeZ) < 1e-9)
        #expect(score.hrvBaseline.status == .provisional)
    }

    @Test func oneSdHrvAboveWithSleepAboveCentre() {
        // HRV one sigma above baseline: 50 + 1.253 x 5 = 56.265, so z_hrv = 1.
        // Sleep performance 0.97 is 0.12 above the 0.85 centre, so z_sleep = 1.
        // No RHR history is supplied, so the RHR term is dropped. The weights are 0.55 (HRV) and
        // 0.15 (sleep), total 0.70. Composite z = (0.55 + 0.15) / 0.70 = 1.0.
        // Score = 100 / (1 + e^(-1.6 x 1.2)) = 87.21.
        let input = Recovery.Input(hrv: 56.265, restingHR: 60, sleepPerformance: 0.97,
                                   hrvHistory: repeated(50, 10))
        guard let score = scored(input) else { Issue.record("expected a score"); return }
        #expect(abs(score.compositeZ - 1.0) < 1e-9)
        #expect(abs(score.score - 87.2138) < 0.001)
        #expect(score.band == .green)
        #expect(score.restingHRBaseline == nil)
        #expect(score.contributions.map(\.driver) == [.hrv, .sleep])
    }

    @Test func contributionWeightsAreRenormalisedAndSumToOne() {
        // All four drivers present. Raw weights are 0.55 + 0.20 + 0.05 + 0.15 = 0.95.
        let input = Recovery.Input(hrv: 52, restingHR: 58, respiratoryRate: 13.5, sleepPerformance: 0.9,
                                   hrvHistory: repeated(50, 10),
                                   restingHRHistory: repeated(60, 10),
                                   respiratoryRateHistory: repeated(14, 10))
        guard let score = scored(input) else { Issue.record("expected a score"); return }
        #expect(score.contributions.map(\.driver) == [.hrv, .restingHR, .respiratoryRate, .sleep])
        let total = score.contributions.reduce(0.0) { $0 + $1.weight }
        #expect(abs(total - 1.0) < 1e-12)
        // HRV share: 0.55 / 0.95.
        #expect(abs(score.contributions[0].weight - 0.55 / 0.95) < 1e-12)
    }

    @Test func weightedZsSumToCompositeZ() {
        let input = Recovery.Input(hrv: 46, restingHR: 64, sleepPerformance: 0.7,
                                   hrvHistory: repeated(50, 10),
                                   restingHRHistory: repeated(60, 10))
        guard let score = scored(input) else { Issue.record("expected a score"); return }
        let fromParts = score.contributions.reduce(0.0) { $0 + $1.weightedZ }
        #expect(abs(fromParts - score.compositeZ) < 1e-12)
    }

    // MARK: - Monotonicity

    @Test func higherHRVRaisesRecovery() {
        let scores = [40.0, 45.0, 50.0, 55.0, 60.0].compactMap { hrv -> Double? in
            scored(Recovery.Input(hrv: hrv, restingHR: 60, hrvHistory: repeated(50, 10),
                                  restingHRHistory: repeated(60, 10)))?.score
        }
        #expect(scores.count == 5)
        #expect(zip(scores, scores.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test func lowerRestingHRRaisesRecovery() {
        let scores = [70.0, 65.0, 60.0, 55.0, 50.0].compactMap { rhr -> Double? in
            scored(Recovery.Input(hrv: 50, restingHR: rhr, hrvHistory: repeated(50, 10),
                                  restingHRHistory: repeated(60, 10)))?.score
        }
        #expect(scores.count == 5)
        #expect(zip(scores, scores.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test func higherSleepPerformanceRaisesRecovery() {
        let scores = [0.6, 0.8, 0.9, 1.0].compactMap { sp -> Double? in
            scored(Recovery.Input(hrv: 50, restingHR: 60, sleepPerformance: sp,
                                  hrvHistory: repeated(50, 10)))?.score
        }
        #expect(scores.count == 4)
        #expect(zip(scores, scores.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test func lowerRespiratoryRateRaisesRecovery() {
        // Respiratory baseline 14 breaths/min, floor 0.5. Sigma = 1.253 x 0.5.
        let scores = [16.0, 14.0, 12.0].compactMap { rr -> Double? in
            scored(Recovery.Input(hrv: 50, restingHR: 60, respiratoryRate: rr,
                                  hrvHistory: repeated(50, 10),
                                  restingHRHistory: repeated(60, 10),
                                  respiratoryRateHistory: repeated(14, 10)))?.score
        }
        #expect(scores.count == 3)
        #expect(zip(scores, scores.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test func respiratoryTermIsHandComputed() {
        // z_resp = (14 - 13) / (1.253 x 0.5) = 1.5962. Weight 0.05 over total 0.80 (HRV 0.55 + RHR 0.20).
        // z_hrv = 0 and z_rhr = 0, so composite z = 0.05 x 1.5962 / 0.80 = 0.09976.
        let input = Recovery.Input(hrv: 50, restingHR: 60, respiratoryRate: 13,
                                   hrvHistory: repeated(50, 10),
                                   restingHRHistory: repeated(60, 10),
                                   respiratoryRateHistory: repeated(14, 10))
        guard let score = scored(input) else { Issue.record("expected a score"); return }
        let expectedZ = 0.05 * ((14.0 - 13.0) / (1.253 * 0.5)) / 0.80
        #expect(abs(score.compositeZ - expectedZ) < 1e-9)
    }

    @Test func hrvBelowBaselineScoresBelowNeutral() {
        let score = scored(Recovery.Input(hrv: 40, restingHR: 60, hrvHistory: repeated(50, 10)))
        #expect((score?.score ?? 100) < 57.93)
    }

    // MARK: - Bands

    @Test func bandCutoffsAreRedBelow34YellowBelow67() {
        #expect(Recovery.band(for: 0) == .red)
        #expect(Recovery.band(for: 33.99) == .red)
        #expect(Recovery.band(for: 34) == .yellow)
        #expect(Recovery.band(for: 66.99) == .yellow)
        #expect(Recovery.band(for: 67) == .green)
        #expect(Recovery.band(for: 100) == .green)
    }

    // MARK: - Missing and insufficient baselines

    @Test func emptyHRVHistoryIsCalibratingZero() {
        let outcome = Recovery.score(Recovery.Input(hrv: 50, restingHR: 60, hrvHistory: []))
        #expect(outcome == .insufficientBaseline(status: .calibrating, validNights: 0))
    }

    @Test func threeNightsIsStillCalibratingAndFourIsUsable() {
        // NOOP `Baselines.minNightsSeed` = 4.
        #expect(Recovery.minNightsSeed == 4)
        let three = Recovery.score(Recovery.Input(hrv: 50, restingHR: 60, hrvHistory: repeated(50, 3)))
        #expect(three == .insufficientBaseline(status: .calibrating, validNights: 3))
        #expect(scored(Recovery.Input(hrv: 50, restingHR: 60, hrvHistory: repeated(50, 4))) != nil)
    }

    @Test func missingNightsDoNotCountTowardTheSeed() {
        // Four valid nights with gaps. A nil is a missing night, so it is skipped, not folded.
        let history: [Double?] = [50, nil, 50, nil, 50, 50]
        let outcome = Recovery.score(Recovery.Input(hrv: 50, restingHR: 60, hrvHistory: history))
        guard case .scored(let score) = outcome else { Issue.record("expected a score"); return }
        #expect(score.hrvBaseline.nValid == 4)
        #expect(abs(score.hrvBaseline.center - 50) < 1e-9)
    }

    @Test func staleBaselineWithholdsScoreAfterFifteenMissingNights() {
        // NOOP `staleDays` = 14. A usable baseline goes stale when nightsSinceUpdate exceeds 14.
        let fourThenMissing: (Int) -> [Double?] = { missing in repeated(50, 4) + Array(repeating: nil, count: missing) }
        #expect(scored(Recovery.Input(hrv: 50, restingHR: 60, hrvHistory: fourThenMissing(14))) != nil)
        let stale = Recovery.score(Recovery.Input(hrv: 50, restingHR: 60, hrvHistory: fourThenMissing(15)))
        #expect(stale == .insufficientBaseline(status: .stale, validNights: 4))
    }

    @Test func absentRestingHRBaselineDropsItsTerm() {
        let score = scored(Recovery.Input(hrv: 50, restingHR: 90, hrvHistory: repeated(50, 10)))
        #expect(score?.restingHRBaseline == nil)
        #expect(score?.contributions.map(\.driver) == [.hrv])
        #expect(score?.contributions.first?.weight == 1.0)
        // Only HRV is present, so z = 0 and the score is the neutral 57.93, regardless of resting HR.
        #expect(abs((score?.score ?? 0) - 57.9324) < 0.001)
    }

    @Test func respiratoryTermNeedsValueAndBaseline() {
        let noValue = scored(Recovery.Input(hrv: 50, restingHR: 60, hrvHistory: repeated(50, 10),
                                            restingHRHistory: repeated(60, 10),
                                            respiratoryRateHistory: repeated(14, 10)))
        #expect(noValue?.respiratoryRateBaseline == nil)
        #expect(noValue?.contributions.contains { $0.driver == .respiratoryRate } == false)

        let noBaseline = scored(Recovery.Input(hrv: 50, restingHR: 60, respiratoryRate: 13,
                                               hrvHistory: repeated(50, 10),
                                               restingHRHistory: repeated(60, 10)))
        #expect(noBaseline?.respiratoryRateBaseline == nil)
        #expect(noBaseline?.contributions.contains { $0.driver == .respiratoryRate } == false)
    }

    // MARK: - Baseline fold (NOOP Baselines.update)

    @Test func implausibleNightIsSkippedNotFolded() {
        // HRV plausible band is 5...250 ms. 1000 is skipped, so it does not count as a valid night.
        let baseline = Recovery.fold([50, 50, 50, 50, 1000], config: .hrv)
        #expect(baseline.nValid == 4)
        #expect(abs(baseline.center - 50) < 1e-9)
    }

    @Test func hardOutlierBeyondFiveSpreadsIsNotFolded() {
        // After 10 nights at 50 ms, the spread is the floor 5. A night at 240 ms is 190 ms away, which
        // is more than 5 x 5 = 25 ms, so it is seen but not folded. The count and centre are unchanged.
        let baseline = Recovery.fold(repeated(50, 10) + [240], config: .hrv)
        #expect(baseline.nValid == 10)
        #expect(abs(baseline.center - 50) < 1e-9)
        #expect(baseline.status == .provisional)
    }

    @Test func sustainedShiftMovesTheCentreTowardTheNewLevel() {
        // Centre half-life is 14 nights, so the gap to 56 shrinks by (1 - 0.04836) per night. After 20
        // nights the remaining gap is 6 x 0.9516^20 = 2.22, so the centre is about 53.78. The shift is
        // followed, not rejected, because 6 ms is well inside 5 x spread.
        let baseline = Recovery.fold(repeated(50, 10) + repeated(56, 20), config: .hrv)
        #expect(baseline.center > 53)
        #expect(baseline.center < 56)
    }

    @Test func statusBoundaries() {
        #expect(Recovery.status(nValid: 3, nightsSinceUpdate: 0) == .calibrating)
        #expect(Recovery.status(nValid: 4, nightsSinceUpdate: 0) == .provisional)
        #expect(Recovery.status(nValid: 13, nightsSinceUpdate: 0) == .provisional)
        #expect(Recovery.status(nValid: 14, nightsSinceUpdate: 0) == .trusted)
        #expect(Recovery.status(nValid: 14, nightsSinceUpdate: 15) == .stale)
    }
}
