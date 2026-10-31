import Foundation
import Testing
@testable import Metrics

/// Stress algo v3: the R-R fallback and thresholds (Part A), and the stimulant-split baselines (Part B).
@Suite("Stress v3: R-R fallback, thresholds and medication-aware baselines")
struct StressMedicationTests {
    private let chicago = TimeZone(identifier: "America/Chicago")!
    private let oct8 = LocalDay(year: 2026, month: 10, day: 8)

    private func localMs(_ day: LocalDay, _ hour: Int) -> Int64 {
        LocalTime.localTime(day, hour: hour, in: chicago)
    }

    private func window(_ startMs: Int64, hr: Double, valid: Bool) -> FiveMinuteWindow {
        FiveMinuteWindow(
            startMs: startMs, hrMean: hr, rrCount: valid ? 225 : 0, rrSumMs: valid ? 180_000 : 0, valid: valid,
            rmssd: nil, sdnn: nil, lnRmssd: valid ? 3.4 : nil, baevskySqrt: nil
        )
    }

    /// Each lookback day (1...14 before `oct8`): 24 unmedicated windows from 08:00 at HR 60 and 12 medicated
    /// windows from 12:00 at HR 75. Every window is valid, and all of them lie outside the 00:00-06:00 night.
    private func splitHistory(unmedicated: Bool = true) -> [FiveMinuteWindow] {
        (1...14).flatMap { offset -> [FiveMinuteWindow] in
            let day = LocalTime.adding(days: -offset, to: oct8)
            let morning = unmedicated
                ? (0..<24).map { window(localMs(day, 8) + Int64($0) * LocalTime.msPerWindow, hr: 60, valid: true) }
                : []
            let midday = (0..<12).map { window(localMs(day, 12) + Int64($0) * LocalTime.msPerWindow, hr: 75, valid: true) }
            return morning + midday
        }
    }

    /// One stimulant window per lookback day and the scored day, 10:00-21:00 local, like an Adderall XR day.
    private func stimulantDays() -> [MedicationWindow] {
        (0...14).map { offset in
            let day = LocalTime.adding(days: -offset, to: oct8)
            return MedicationWindow(
                medicationID: "adderall", medClass: .stimulant,
                startMs: localMs(day, 10), endMs: localMs(day, 21)
            )
        }
    }

    private func build(_ windows: [FiveMinuteWindow], stimulant: [MedicationWindow] = []) -> StressBaseline {
        StressBaseline.build(
            windows: windows, day: oct8, nights: SleepNights(sleep: [], in: chicago),
            restingHR: 60, maxHR: 180, stimulantWindows: stimulant
        )
    }

    /// The scored window: 12:00 on the scored day, valid, HR 75.
    private var medicatedCurrent: FiveMinuteWindow {
        window(localMs(oct8, 12), hr: 75, valid: true)
    }

    // MARK: Part A: thresholds and the fallback

    @Test func twelveValidWindowsQualifyAnRRDayAndElevenDoNot() {
        let twelve = (1...8).flatMap { offset -> [FiveMinuteWindow] in
            let day = LocalTime.adding(days: -offset, to: oct8)
            return (0..<24).map { window(localMs(day, 8) + Int64($0) * LocalTime.msPerWindow, hr: 60, valid: $0 < 12) }
        }
        let baseline = build(twelve)
        #expect(baseline.validDays == 8)
        #expect(baseline.hrOnlyDays == 8)
        #expect(baseline.requiredDays == Stress.minQualifyingDays)

        let eleven = (1...8).flatMap { offset -> [FiveMinuteWindow] in
            let day = LocalTime.adding(days: -offset, to: oct8)
            return (0..<24).map { window(localMs(day, 8) + Int64($0) * LocalTime.msPerWindow, hr: 60, valid: $0 < 11) }
        }
        #expect(build(eleven).validDays == 0)
        #expect(build(eleven).hrOnlyDays == 8)
    }

    @Test func calibrationProgressUsesTheTwelveWindowRRRule() throws {
        let day = LocalTime.adding(days: -1, to: oct8)
        let windows = (0..<24).map { window(localMs(day, 8) + Int64($0) * LocalTime.msPerWindow, hr: 60, valid: $0 < 12) }
        let progress = Stress.calibrationProgress(
            windows: windows, day: oct8, nights: SleepNights(sleep: [], in: chicago), restingHR: 60, maxHR: 180
        )
        let latest = try #require(progress.latestDay)
        #expect(latest.requiredWindows == 12)
        #expect(latest.requiredHRWindows == 24)
        #expect(latest.qualifiesForRR)
        // 24 windows with HR meet the HR-only rule too.
        #expect(latest.qualifiesForHROnly)
        #expect(progress.qualifyingDays == 1)
    }

    // MARK: Part B: medication-aware baselines

    @Test func contextBaselinesHaveTheirOwnThresholdsAndTheCombinedOneStaysSeven() throws {
        let baseline = build(splitHistory(), stimulant: stimulantDays())
        #expect(baseline.requiredDays == Stress.minQualifyingDays)
        let medicated = try #require(baseline.context(.medicated))
        let unmedicated = try #require(baseline.context(.unmedicated))
        #expect(medicated.requiredDays == Stress.minContextQualifyingDays)
        #expect(medicated.validDays == 14)
        #expect(medicated.hrMedian == 75)
        #expect(unmedicated.hrMedian == 60)
        #expect(unmedicated.hrOnlyDays == 14)
    }

    @Test func medicatedWindowAtItsContextMedianScoresAboutThirtyThree() {
        let baseline = build(splitHistory(), stimulant: stimulantDays())
        let result = Stress.score(
            window: medicatedCurrent, restingHR: 60, maxHR: 180, baseline: baseline,
            stimulantWindows: stimulantDays()
        )
        // The medicated baseline is 75 bpm with no spread, so z_HR = 0 and z_HRV = 0. Phi(-0.44) gives 33.
        #expect(result == StressResult(stress: 33, state: .value, baselineContext: .medicated))
    }

    @Test func withoutStimulantWindowsTheSameWindowScoresMuchHigher() {
        // The combined median is 60 (24 of every 36 windows are unmedicated) with no spread, so +15 bpm is 3.75 sigma.
        // raw = 0.5 * 3.75 = 1.875, and Phi(1.875 - 0.44) = 0.92 gives 92.
        let baseline = build(splitHistory())
        let result = Stress.score(window: medicatedCurrent, restingHR: 60, maxHR: 180, baseline: baseline)
        #expect(result == StressResult(stress: 92, state: .value, baselineContext: .combined))
    }

    @Test func notReadyContextFallsBackToTheCombinedBaseline() {
        // Stimulant windows are present, but no medicated windows exist in the lookback, so the medicated
        // baseline has no qualifying days and the combined baseline scores the window.
        let baseline = build(splitHistory(unmedicated: true).filter { $0.hrMean == 60 }, stimulant: stimulantDays())
        #expect(baseline.context(.medicated)?.validDays == 0)
        let result = Stress.score(
            window: medicatedCurrent, restingHR: 60, maxHR: 180, baseline: baseline,
            stimulantWindows: stimulantDays()
        )
        #expect(result.baselineContext == .combined)
        #expect(result.stress == 92)
    }

    @Test func emptyStimulantWindowsGiveTheCombinedBaselineAlone() {
        let windows = splitHistory()
        let plain = build(windows)
        let empty = build(windows, stimulant: [])
        #expect(plain == empty)
        #expect(empty.contexts.isEmpty)

        let current = medicatedCurrent
        let withoutList = Stress.score(window: current, restingHR: 60, maxHR: 180, baseline: plain)
        let withEmptyList = Stress.score(
            window: current, restingHR: 60, maxHR: 180, baseline: plain, stimulantWindows: []
        )
        #expect(withoutList == withEmptyList)
        #expect(withEmptyList.baselineContext == .combined)
    }

    @Test func unmedicatedWindowUsesTheUnmedicatedBaseline() {
        // 08:00 is outside the stimulant window, so it is scored against the 60 bpm unmedicated baseline.
        let baseline = build(splitHistory(), stimulant: stimulantDays())
        let morning = window(localMs(oct8, 8), hr: 60, valid: true)
        let result = Stress.score(
            window: morning, restingHR: 60, maxHR: 180, baseline: baseline, stimulantWindows: stimulantDays()
        )
        #expect(result == StressResult(stress: 33, state: .value, baselineContext: .unmedicated))
    }
}
