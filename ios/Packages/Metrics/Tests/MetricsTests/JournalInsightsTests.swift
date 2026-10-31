import Foundation
import Testing
@testable import Metrics

@Suite("Journal insights: with vs without comparisons")
struct JournalInsightsTests {
    private func day(_ behaviour: String, _ answer: Bool?, recovery: Double?) -> JournalInsights.Day {
        JournalInsights.Day(
            behaviours: answer.map { [behaviour: $0] } ?? [:],
            outcome: JournalInsights.Outcome(recoveryPct: recovery)
        )
    }

    private func effect(_ effects: [JournalInsights.Effect], _ behaviour: String, _ metric: JournalInsights.Metric) -> JournalInsights.Effect? {
        effects.first { $0.behaviour == behaviour && $0.metric == metric }
    }

    @Test func meansAndDifferenceSplitByAnswer() throws {
        // Alcohol yes: 50, 60, 70 (mean 60). No: 80, 90 (mean 85).
        let days = [
            day("alcohol", true, recovery: 50),
            day("alcohol", true, recovery: 60),
            day("alcohol", true, recovery: 70),
            day("alcohol", false, recovery: 80),
            day("alcohol", false, recovery: 90),
        ]
        let found = try #require(effect(JournalInsights.effects(for: days), "alcohol", .recovery))
        #expect(found.with.days == 3)
        #expect(found.without.days == 2)
        #expect(found.with.mean == 60)
        #expect(found.without.mean == 85)
        #expect(found.difference == -25)
        // Sample SD: yes 10, no sqrt(50).
        #expect(abs((found.with.standardDeviation ?? 0) - 10) < 1e-9)
        #expect(abs((found.without.standardDeviation ?? 0) - 50.0.squareRoot()) < 1e-9)
    }

    @Test func effectSizeIsDifferenceOverPooledStandardDeviation() throws {
        let days = [
            day("a", true, recovery: 50), day("a", true, recovery: 60), day("a", true, recovery: 70),
            day("a", false, recovery: 80), day("a", false, recovery: 90),
        ]
        let found = try #require(effect(JournalInsights.effects(for: days), "a", .recovery))
        let pooled = ((2.0 * 100 + 1.0 * 50) / 3).squareRoot()
        let size = try #require(found.effectSize)
        #expect(abs(size - (-25 / pooled)) < 1e-9)
    }

    @Test func confidenceNeedsFiveDaysOnEachSide() {
        let fiveAndFive = (0..<10).map { index in day("a", index < 5, recovery: Double(index)) }
        let confident = effect(JournalInsights.effects(for: fiveAndFive), "a", .recovery)
        #expect(confident?.isConfident == true)
        #expect(confident?.moreDaysNeeded == 0)

        let fourAndTen = (0..<14).map { index in day("a", index < 4, recovery: Double(index)) }
        let thin = effect(JournalInsights.effects(for: fourAndTen), "a", .recovery)
        #expect(thin?.isConfident == false)
        #expect(thin?.moreDaysNeeded == 1)
    }

    @Test func unansweredAndMissingOutcomesCountOnNeitherSide() {
        let days = [
            day("a", true, recovery: 50),
            day("a", nil, recovery: 10),     // not answered
            day("a", false, recovery: nil),  // no outcome
            day("a", false, recovery: 70),
        ]
        let found = effect(JournalInsights.effects(for: days), "a", .recovery)
        #expect(found?.with.days == 1)
        #expect(found?.without.days == 1)
        #expect(found?.with.mean == 50)
        #expect(found?.without.mean == 70)
        #expect(found?.with.standardDeviation == nil)
        #expect(found?.effectSize == nil)
    }

    @Test func emptySideHasNoMeanOrDifference() {
        let days = (0..<6).map { day("a", true, recovery: Double($0)) }
        let found = effect(JournalInsights.effects(for: days), "a", .recovery)
        #expect(found?.without.days == 0)
        #expect(found?.without.mean == nil)
        #expect(found?.difference == nil)
        #expect(found?.isConfident == false)
        #expect(found?.moreDaysNeeded == 5)
    }

    @Test func everyMetricIsComputedPerBehaviour() {
        let days = [
            JournalInsights.Day(
                behaviours: ["med:x": true],
                outcome: JournalInsights.Outcome(recoveryPct: 60, sleepPerformancePct: 80, hrvMs: 40)
            ),
            JournalInsights.Day(
                behaviours: ["med:x": false],
                outcome: JournalInsights.Outcome(recoveryPct: 70, sleepPerformancePct: 90, hrvMs: 50)
            ),
        ]
        let effects = JournalInsights.effects(for: days)
        #expect(effects.count == JournalInsights.Metric.allCases.count)
        #expect(effect(effects, "med:x", .sleepPerformance)?.difference == -10)
        #expect(effect(effects, "med:x", .hrv)?.difference == -10)
    }

    @Test func noDaysNoEffects() {
        #expect(JournalInsights.effects(for: []).isEmpty)
    }
}
