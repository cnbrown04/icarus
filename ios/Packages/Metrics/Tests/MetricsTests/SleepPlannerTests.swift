import Foundation
import Testing
@testable import Metrics

@Suite("SleepPlanner: bedtimes for Peak, Perform and Get by (our heuristic)")
struct SleepPlannerTests {
    private let chicago = TimeZone(identifier: "America/Chicago")!
    private let hour: Double = 3600

    /// Unix seconds of local `hour`:`minute` on the given 2026 day in Chicago.
    private func local(month: Int, day: Int, hour: Int, minute: Int = 0) -> Int64 {
        LocalTime.localTime(LocalDay(year: 2026, month: month, day: day), hour: hour, in: chicago) / 1000
            + Int64(minute) * 60
    }

    /// Latency zero and efficiency one, so time in bed is exactly need x target.
    private let ideal = SleepPlanner.Timing(latencySec: 0, efficiency: 1, isDefault: false)

    // MARK: - Arithmetic

    @Test func targetsAreTheShareOfNeed() {
        #expect(SleepPlanner.Target.peak.fraction == 1.0)
        #expect(SleepPlanner.Target.perform.fraction == 0.85)
        #expect(SleepPlanner.Target.getBy.fraction == 0.70)
        #expect(SleepPlanner.Target.allCases.map(\.label) == ["Peak", "Perform", "Get By"])
    }

    @Test func timeInBedIsNeedTimesTargetOverEfficiencyPlusLatency() {
        let timing = SleepPlanner.Timing(latencySec: 900, efficiency: 0.9, isDefault: false)
        // 8 h x 0.85 / 0.9 + 15 min = 7.5556 h + 0.25 h.
        let seconds = SleepPlanner.timeInBedSec(needSec: 8 * hour, target: .perform, timing: timing)
        #expect(seconds == Int64((8 * hour * 0.85 / 0.9 + 900).rounded()))
    }

    @Test func plansAreOrderedPeakPerformGetByAndEarlierForLessSleep() throws {
        let wake = local(month: 10, day: 31, hour: 6, minute: 30)
        let plans = SleepPlanner.plans(wakeSec: wake, needSec: 8 * hour, timing: ideal)
        #expect(plans.map(\.target) == [.peak, .perform, .getBy])
        // With no latency and no inefficiency, bedtime is simply wake minus need x target.
        #expect(plans.map { wake - $0.bedtimeSec } == [28_800, 24_480, 20_160])
        #expect(plans[0].bedtimeSec < plans[1].bedtimeSec)
        #expect(plans[1].bedtimeSec < plans[2].bedtimeSec)
    }

    @Test func nonPositiveNeedGivesNoPlans() {
        #expect(SleepPlanner.plans(wakeSec: 0, needSec: 0, timing: ideal).isEmpty)
        #expect(SleepPlanner.plans(wakeSec: 0, needSec: -5, timing: ideal).isEmpty)
    }

    // MARK: - Midnight and DST

    @Test func bedtimeCrossesMidnightToThePreviousCalendarDay() throws {
        // Wake 06:30 on Oct 31. Peak needs 8 h in bed, so bed is 22:30 on Oct 30.
        let wake = local(month: 10, day: 31, hour: 6, minute: 30)
        let peak = try #require(SleepPlanner.plans(wakeSec: wake, needSec: 8 * hour, timing: ideal).first)
        #expect(peak.bedtimeSec == local(month: 10, day: 30, hour: 22, minute: 30))
        let zone = LocalTime.localDay(containing: peak.bedtimeSec * 1000, in: chicago)
        #expect(zone == LocalDay(year: 2026, month: 10, day: 30))
    }

    @Test func aNightAcrossSpringForwardKeepsItsAbsoluteLength() throws {
        // DST starts 2026-03-08 at 02:00 in Chicago. Wake 06:30 CDT is 11:30 UTC.
        let wake = local(month: 3, day: 8, hour: 6, minute: 30)
        let peak = try #require(SleepPlanner.plans(wakeSec: wake, needSec: 8 * hour, timing: ideal).first)
        // Eight real hours before 06:30 CDT is 21:30 CST on Mar 7, which is a 9 h wall-clock gap.
        #expect(wake - peak.bedtimeSec == 28_800)
        #expect(peak.bedtimeSec == local(month: 3, day: 7, hour: 21, minute: 30))
    }

    @Test func aNightAcrossFallBackKeepsItsAbsoluteLength() throws {
        // DST ends 2026-11-01 at 02:00 CDT, which becomes 01:00 CST. Wake 06:30 CST is 12:30 UTC.
        // Eight real hours earlier is 04:30 UTC, which is 23:30 CDT on Oct 31.
        let wake = local(month: 11, day: 1, hour: 6, minute: 30)
        let peak = try #require(SleepPlanner.plans(wakeSec: wake, needSec: 8 * hour, timing: ideal).first)
        #expect(wake - peak.bedtimeSec == 28_800)
        #expect(peak.bedtimeSec == local(month: 10, day: 31, hour: 23, minute: 30))
    }

    // MARK: - Timing from recent nights

    @Test func timingIsTheMedianOfRecentNights() {
        let timing = SleepPlanner.timing(latenciesSec: [600, 1200, 900], efficiencies: [0.88, 0.94, 0.92, 0.90])
        #expect(timing.latencySec == 900)
        #expect(abs(timing.efficiency - 0.91) < 1e-9)
        #expect(!timing.isDefault)
    }

    @Test func noRecentNightsUsesTheDefaultsAndSaysSo() {
        let timing = SleepPlanner.timing(latenciesSec: [], efficiencies: [])
        #expect(timing.latencySec == SleepPlanner.defaultLatencySec)
        #expect(timing.efficiency == SleepPlanner.defaultEfficiency)
        #expect(timing.isDefault)
    }

    @Test func implausibleMeasurementsAreBounded() {
        // A negative latency is discarded, and the remaining 9000 s is capped at one hour.
        let low = SleepPlanner.timing(latenciesSec: [-5, 9_000], efficiencies: [0.2])
        #expect(low.efficiency == 0.5)
        #expect(low.latencySec == 3_600)
        let high = SleepPlanner.timing(latenciesSec: [], efficiencies: [1.4])
        #expect(high.efficiency == SleepPlanner.defaultEfficiency, "efficiency above 1 is discarded, not clamped")
    }

    @Test func medianOfEvenAndOddCounts() {
        #expect(SleepPlanner.median([3, 1, 2]) == 2)
        #expect(SleepPlanner.median([4, 1, 3, 2]) == 2.5)
        #expect(SleepPlanner.median([]) == nil)
    }
}
