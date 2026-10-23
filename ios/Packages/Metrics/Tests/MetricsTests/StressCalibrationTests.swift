import Foundation
import Testing
@testable import Metrics

@Suite("Stress: calibration progress (PLAN.md 8.3)")
struct StressCalibrationTests {
    private let chicago = TimeZone(identifier: "America/Chicago")!
    private let oct8 = LocalDay(year: 2026, month: 10, day: 8)

    /// `count` five-minute windows starting at 00:00 local on the night `offset` days before the scored day.
    /// `valid` of them pass the R-R rule; every window has a heart rate.
    private func night(offset: Int, count: Int = 12, valid: Int, hr: Double = 60) -> [FiveMinuteWindow] {
        let day = LocalTime.adding(days: -offset, to: oct8)
        let start = LocalTime.localTime(day, hour: 0, in: chicago)
        return (0..<count).map { index in
            let isValid = index < valid
            return FiveMinuteWindow(
                startMs: start + Int64(index) * LocalTime.msPerWindow,
                hrMean: hr,
                rrCount: 0,
                rrSumMs: 0,
                valid: isValid,
                rmssd: nil,
                sdnn: nil,
                lnRmssd: isValid ? 3.4 : nil,
                baevskySqrt: nil
            )
        }
    }

    private func progress(_ windows: [FiveMinuteWindow]) -> StressCalibrationProgress {
        Stress.calibrationProgress(
            windows: windows, day: oct8, nights: SleepNights(sleep: [], in: chicago), restingHR: 60, maxHR: 180
        )
    }

    @Test func noNightsIsZeroOfSeven() {
        let progress = progress([])
        #expect(progress.qualifyingDays == 0)
        #expect(progress.requiredDays == 7)
        #expect(progress.lookbackDays == 14)
        #expect(progress.hrOnlyDays == 0)
        #expect(progress.daysNeeded == 7)
        #expect(!progress.isCalibrated)
        #expect(progress.nights.count == 14)
        #expect(progress.nights.map(\.offset) == Array(1...14))
        #expect(progress.latestNight?.offset == 1)
        #expect(progress.nights.allSatisfy { !$0.qualifiesForRR && !$0.qualifiesForHROnly })
    }

    @Test func threeQualifyingNightsIsThreeOfSeven() {
        var windows: [FiveMinuteWindow] = []
        for offset in 1...3 {
            windows += night(offset: offset, valid: 12)
        }
        let progress = progress(windows)
        #expect(progress.qualifyingDays == 3)
        #expect(progress.daysNeeded == 4)
        #expect(!progress.isCalibrated)
        #expect(progress.hrOnlyDays == 3)
        #expect(progress.nights.prefix(3).allSatisfy { $0.qualifiesForRR })
        #expect(!progress.nights[3].qualifiesForRR)
    }

    @Test func sevenQualifyingNightsIsReady() {
        var windows: [FiveMinuteWindow] = []
        for offset in 1...7 {
            windows += night(offset: offset, valid: 12)
        }
        let progress = progress(windows)
        #expect(progress.qualifyingDays == 7)
        #expect(progress.daysNeeded == 0)
        #expect(progress.isCalibrated)
        #expect(progress.hrOnlyDays == 7)
        #expect(progress.isHROnlyCalibrated)
    }

    @Test func lookbackCountsOnlyTheFourteenPriorNights() {
        var windows: [FiveMinuteWindow] = []
        for offset in 1...3 {
            windows += night(offset: offset, valid: 12)
        }
        // Offset 14 is the oldest night inside the window. Offsets 0 and 15 are outside it.
        windows += night(offset: 14, valid: 12)
        windows += night(offset: 15, valid: 12)
        windows += night(offset: 0, valid: 12)

        let progress = progress(windows)
        #expect(progress.qualifyingDays == 4)
        let days = Set(progress.nights.map(\.day))
        #expect(!days.contains(oct8))
        #expect(!days.contains(LocalTime.adding(days: -15, to: oct8)))
        #expect(days.contains(LocalTime.adding(days: -14, to: oct8)))
        #expect(progress.nights.map(\.offset) == Array(1...14))
    }

    @Test func hrOnlyPathIsReportedSeparately() throws {
        var windows: [FiveMinuteWindow] = []
        for offset in 1...5 {
            windows += night(offset: offset, valid: 0)
        }
        let progress = progress(windows)
        #expect(progress.qualifyingDays == 0)
        #expect(progress.hrOnlyDays == 5)
        #expect(progress.hrOnlyDaysNeeded == 2)
        #expect(!progress.isCalibrated)
        #expect(!progress.isHROnlyCalibrated)

        let latest = try #require(progress.latestNight)
        #expect(latest.validWindowCount == 0)
        #expect(latest.hrWindowCount == 12)
        #expect(latest.qualifiesForHROnly)
        #expect(!latest.qualifiesForRR)
        #expect(latest.validWindowsNeeded == 12)
        #expect(latest.validMinutesNeeded == 60)
    }

    @Test func shortfallReportsWindowsAndMinutesNeeded() throws {
        let progress = progress(night(offset: 1, count: 5, valid: 5))
        let latest = try #require(progress.latestNight)
        #expect(latest.validWindowCount == 5)
        #expect(latest.validWindowsNeeded == 7)
        #expect(latest.validMinutesNeeded == 35)
        #expect(latest.hrWindowCount == 5)
        #expect(latest.hrWindowsNeeded == 7)
        #expect(latest.hrMinutesNeeded == 35)
    }

    @Test func progressCountsMatchTheBaselineBuilder() {
        var windows: [FiveMinuteWindow] = []
        for offset in 1...3 {
            windows += night(offset: offset, valid: 12)
        }
        for offset in 4...5 {
            windows += night(offset: offset, valid: 0)
        }
        let baseline = StressBaseline.build(
            windows: windows, day: oct8, nights: SleepNights(sleep: [], in: chicago), restingHR: 60, maxHR: 180
        )
        let progress = progress(windows)
        #expect(progress.qualifyingDays == baseline.validDays)
        #expect(progress.hrOnlyDays == baseline.hrOnlyDays)
    }

    @Test func exertionNightsDoNotCountTowardProgress() {
        // HRR = (150 - 60) / (180 - 60) = 0.75, above the 0.40 exertion gate.
        let windows = (1...7).flatMap { offset in
            night(offset: offset, valid: 12, hr: 150)
        }
        let progress = progress(windows)
        #expect(progress.qualifyingDays == 0)
        #expect(progress.hrOnlyDays == 0)
        #expect(progress.nights.allSatisfy { $0.validWindowCount == 0 && $0.hrWindowCount == 0 })
    }
}
