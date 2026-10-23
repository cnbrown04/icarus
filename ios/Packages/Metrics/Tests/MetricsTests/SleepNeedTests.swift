import Foundation
import Testing
@testable import Metrics

@Suite("SleepNeed, SleepDebt and SleepPerformance (sleep coaching)")
struct SleepNeedTests {
    private let chicago = TimeZone(identifier: "America/Chicago")!
    private let hour: Double = 3600

    /// Local 06:00 on the given October 2026 day, in Unix seconds.
    private func wakeTime(day: Int) -> Int64 {
        LocalTime.localTime(LocalDay(year: 2026, month: 10, day: day), hour: 6, in: chicago) / 1000
    }

    /// A main night that ends at 06:00 on `day` after `asleepHours` of sleep.
    private func mainNight(wakeDay day: Int, asleepHours: Double) -> SleepNight {
        let end = wakeTime(day: day)
        return SleepNight(startSec: end - Int64(asleepHours * 3600), endSec: end, asleepSec: asleepHours * 3600)
    }

    /// A nap that ends at 15:00 on `day`, so it falls on the same wake day as that day's main night.
    private func nap(day: Int, asleepHours: Double) -> SleepNight {
        let end = LocalTime.localTime(LocalDay(year: 2026, month: 10, day: day), hour: 15, in: chicago) / 1000
        return SleepNight(startSec: end - Int64(asleepHours * 3600), endSec: end, asleepSec: asleepHours * 3600, isNap: true)
    }

    // MARK: - Sleep need

    @Test func needIsBaselineWithoutStrainOrDebt() {
        #expect(SleepNeed.adjustedNeedSec(dayStrain: nil) == 8 * hour)
    }

    @Test func strainBonusScalesLinearlyToFortyFiveMinutes() {
        #expect(SleepNeed.strainBonusSec(dayStrain: 21) == 45 * 60)
        #expect(SleepNeed.strainBonusSec(dayStrain: 10.5) == 22.5 * 60)
        // Strain above 21 and below 0 is clamped, as OpenStrap coaching.dart does.
        #expect(SleepNeed.strainBonusSec(dayStrain: 30) == 45 * 60)
        #expect(SleepNeed.strainBonusSec(dayStrain: -4) == 0)
        // An unknown strain adds nothing.
        #expect(SleepNeed.strainBonusSec(dayStrain: nil) == 0)
    }

    @Test func needRisesWithStrain() {
        let needs = [0.0, 5, 10, 15, 21].map { SleepNeed.adjustedNeedSec(dayStrain: $0) }
        #expect(zip(needs, needs.dropFirst()).allSatisfy { $0 < $1 })
        #expect(needs.last == 8 * hour + 45 * 60)
    }

    @Test func needAddsDebtAndSubtractsNapCredit() {
        // 8 h baseline + 1 h debt - 30 min nap credit = 8.5 h.
        #expect(SleepNeed.adjustedNeedSec(sleepDebtSec: hour, dayStrain: nil, napCreditSec: 1800) == 8.5 * hour)
    }

    @Test func needClampsToSixAndElevenHours() {
        #expect(SleepNeed.adjustedNeedSec(baselineNeedSec: 5 * hour, dayStrain: nil) == 6 * hour)
        #expect(SleepNeed.adjustedNeedSec(baselineNeedSec: 12 * hour, dayStrain: nil) == 11 * hour)
        // The clamp covers the whole sum, so debt and strain cannot push the need past 11 h.
        #expect(SleepNeed.adjustedNeedSec(baselineNeedSec: 10 * hour, sleepDebtSec: 3 * hour, dayStrain: 21) == 11 * hour)
    }

    // MARK: - Sleep debt

    @Test func weekOfSixHourNightsAccumulatesDebt() {
        let nights = (10...16).map { mainNight(wakeDay: $0, asleepHours: 6) }

        // First night: 0.55 * (8 h - 6 h) = 66 min.
        let first = SleepDebt.ledger(nights: [nights[0]], timeZone: chicago)
        #expect(abs(first.balanceSec - (-66 * 60)) < 1e-6)

        // Debt grows every night, toward the fixed point 66 / 0.45 = 146.7 min. After seven nights it
        // is about 144.4 min (8666 s).
        let week = SleepDebt.ledger(nights: nights, timeZone: chicago)
        #expect(week.nightCount == 7)
        #expect(week.balanceSec < -8400 && week.balanceSec > -8800)
        let balances = (1...7).map { SleepDebt.ledger(nights: Array(nights.prefix($0)), timeZone: chicago).balanceSec }
        #expect(zip(balances, balances.dropFirst()).allSatisfy { $1 < $0 })
    }

    @Test func ledgerCountsOnlyTheMostRecentFourteenNights() {
        let nights = (1...20).map { mainNight(wakeDay: $0, asleepHours: 6) }
        let full = SleepDebt.ledger(nights: nights, timeZone: chicago)
        let fortnight = SleepDebt.ledger(nights: Array(nights.suffix(14)), timeZone: chicago)
        #expect(full.nightCount == 14)
        #expect(full.balanceSec == fortnight.balanceSec)
    }

    @Test func longNightClearsCarriedDebt() {
        // Night one leaves 66 min of debt. Night two is 10 h, so 0.55 * max(0, 480 + 66 - 600) = 0.
        let nights = [mainNight(wakeDay: 10, asleepHours: 6), mainNight(wakeDay: 11, asleepHours: 10)]
        #expect(SleepDebt.ledger(nights: nights, timeZone: chicago).balanceSec == 0)
    }

    @Test func residualDebtUnderTenMinutesClears() {
        // 7 h 50 min: 0.55 * 10 = 5.5 min, below the 10-minute floor, so it clears.
        let small = SleepDebt.ledger(nights: [mainNight(wakeDay: 10, asleepHours: 470.0 / 60)], timeZone: chicago)
        #expect(small.balanceSec == 0)
        // 7 h 30 min: 0.55 * 30 = 16.5 min, above the floor, so it stays. That is 990 s.
        let kept = SleepDebt.ledger(nights: [mainNight(wakeDay: 10, asleepHours: 7.5)], timeZone: chicago)
        #expect(abs(kept.balanceSec - (-990)) < 1e-6)
    }

    @Test func napCreditRepaysDebtOnTheSameWakeDay() {
        // A 6 h main night plus a 1 h nap that day is credited as 7 h, so the debt is 0.55 * 60 = 33 min.
        let nights = [mainNight(wakeDay: 10, asleepHours: 6), nap(day: 10, asleepHours: 1)]
        let ledger = SleepDebt.ledger(nights: nights, timeZone: chicago)
        #expect(abs(ledger.balanceSec - (-33 * 60)) < 1e-6)
        #expect(ledger.nights.first?.creditedSec == 7 * hour)
    }

    @Test func napOnlyDayIsSkipped() {
        // A day with no main sleep has no debt observation, so it is never zero-filled.
        let ledger = SleepDebt.ledger(nights: [nap(day: 10, asleepHours: 2)], timeZone: chicago)
        #expect(ledger.nightCount == 0)
        #expect(ledger.balanceSec == 0)
    }

    @Test func mainBlocksOnOneDayAreSummed() {
        // Two 3 h blocks on the same wake day form one 6 h main night.
        let first = SleepNight(startSec: wakeTime(day: 10) - 4 * 3600, endSec: wakeTime(day: 10) - 3 * 3600, asleepSec: 3 * hour)
        let second = SleepNight(startSec: wakeTime(day: 10) - 2 * 3600, endSec: wakeTime(day: 10), asleepSec: 3 * hour)
        let ledger = SleepDebt.ledger(nights: [first, second], timeZone: chicago)
        #expect(ledger.nightCount == 1)
        #expect(ledger.nights.first?.creditedSec == 6 * hour)
    }

    @Test func emptyLedgerIsOnTarget() {
        let ledger = SleepDebt.ledger(nights: [], timeZone: chicago)
        #expect(ledger.nightCount == 0)
        #expect(ledger.balanceSec == 0)
    }

    @Test func blocksWithoutSleepAreIgnored() {
        let empty = SleepNight(startSec: wakeTime(day: 10) - 3600, endSec: wakeTime(day: 10), asleepSec: 0)
        #expect(SleepDebt.ledger(nights: [empty], timeZone: chicago).nightCount == 0)
    }

    // MARK: - Sleep performance

    @Test func performanceIsAsleepOverNeed() {
        #expect(SleepPerformance.percent(asleepSec: 6 * hour, needSec: 8 * hour) == 75)
    }

    @Test func performanceCapsAtOneHundred() {
        // OpenStrap sleepPerformance clamps to 100. NOOP's duration term clamps the ratio to 1.0.
        #expect(SleepPerformance.percent(asleepSec: 10 * hour, needSec: 8 * hour) == 100)
    }

    @Test func performanceIsNilWithoutPositiveNeed() {
        #expect(SleepPerformance.percent(asleepSec: 6 * hour, needSec: 0) == nil)
        #expect(SleepPerformance.percent(asleepSec: 6 * hour, needSec: -1) == nil)
    }

    @Test func performanceFloorsAtZero() {
        #expect(SleepPerformance.percent(asleepSec: -5, needSec: 8 * hour) == 0)
    }

    // MARK: - Summary

    @Test func summaryIsNilWithoutNights() {
        #expect(SleepCoaching.summarize(nights: [], dayStrain: 10, timeZone: chicago) == nil)
    }

    @Test func oneNightHasNoCarriedDebtAndUsesStrain() throws {
        let summary = try #require(SleepCoaching.summarize(
            nights: [mainNight(wakeDay: 12, asleepHours: 6)],
            dayStrain: 21,
            timeZone: chicago
        ))
        #expect(summary.carriedDebtSec == 0)
        #expect(summary.needSec == 8 * hour + 45 * 60)
        #expect(summary.asleepSec == 6 * hour)
        #expect(abs(summary.performancePct - 6 / 8.75 * 100) < 1e-9)
        #expect(abs(summary.debtBalanceSec - (-66 * 60)) < 1e-6)
    }

    @Test func summaryCarriesDebtIntoTheLatestNight() throws {
        // Night one (6 h) leaves 66 min of debt, so the need for night two is 8 h + 3960 s = 32760 s.
        let summary = try #require(SleepCoaching.summarize(
            nights: [mainNight(wakeDay: 12, asleepHours: 6), mainNight(wakeDay: 13, asleepHours: 6)],
            dayStrain: nil,
            timeZone: chicago
        ))
        #expect(abs(summary.carriedDebtSec - 3960) < 1e-6)
        #expect(abs(summary.needSec - 32760) < 1e-6)
        #expect(abs(summary.performancePct - 21600 / 32760 * 100) < 1e-9)
        #expect(summary.debtBalanceSec < -3960)
    }

    @Test func napsCountTowardDebtButNotPerformance() throws {
        // Day 13 has a 6 h main night and a 1 h nap. Performance uses the 6 h main night only. The nap
        // is credited in the balance: 0.55 * (480 + 66 - 420) min = 69.3 min = 4158 s.
        let summary = try #require(SleepCoaching.summarize(
            nights: [
                mainNight(wakeDay: 12, asleepHours: 6),
                mainNight(wakeDay: 13, asleepHours: 6),
                nap(day: 13, asleepHours: 1),
            ],
            dayStrain: nil,
            timeZone: chicago
        ))
        #expect(summary.asleepSec == 6 * hour)
        #expect(abs(summary.carriedDebtSec - 3960) < 1e-6)
        #expect(abs(summary.debtBalanceSec - (-4158)) < 1e-6)
    }
}
