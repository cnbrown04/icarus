import Foundation
import Testing
@testable import Metrics

@Suite("Stress: baseline and score (PLAN.md 8.3)")
struct StressTests {
    private let chicago = TimeZone(identifier: "America/Chicago")!
    private let oct8 = LocalDay(year: 2026, month: 10, day: 8)

    /// Median HR 60 (MAD 1), median lnRMSSD 3.4 (MAD 0.06), both calibrated unless the caller says otherwise.
    /// The sigma floors apply here: HR sigma is max(1.4826, 4) = 4 and lnRMSSD sigma is max(0.089, 0.15) = 0.15.
    private func baseline(validDays: Int = 7, hrOnlyDays: Int = 7) -> StressBaseline {
        StressBaseline(
            validDays: validDays, hrMedian: 60, hrMAD: 1, lnRmssdMedian: 3.4, lnRmssdMAD: 0.06,
            hrOnlyDays: hrOnlyDays, hrOnlyMedian: 60, hrOnlyMAD: 1
        )
    }

    private func window(hr: Double?, lnRmssd: Double? = 3.4, valid: Bool = true) -> FiveMinuteWindow {
        FiveMinuteWindow(
            startMs: 0, hrMean: hr, rrCount: valid ? 225 : 0, rrSumMs: valid ? 180_000 : 0, valid: valid,
            rmssd: nil, sdnn: nil, lnRmssd: valid ? lnRmssd : nil, baevskySqrt: nil
        )
    }

    private func score(_ window: FiveMinuteWindow, _ baseline: StressBaseline) -> StressResult {
        Stress.score(window: window, restingHR: 60, maxHR: 180, baseline: baseline)
    }

    @Test func medianWindowScoresAboutThirtyThree() {
        // z_HR = 0 and z_HRV = 0, so raw = 0 and the centre offset gives Phi(-0.44) = 0.330. Stress = 33.
        #expect(score(window(hr: 60), baseline()) == StressResult(stress: 33, state: .value))
    }

    @Test func valueMatchesHandComputedScore() {
        // sigma_HR = max(1.4826 * 1.0, 4.0) = 4.0; sigma_HRV = max(1.4826 * 0.06, 0.15) = 0.15.
        // z_HR  = (62 - 60) / 4.0    = 0.5
        // z_HRV = (3.45 - 3.4) / 0.15 = 0.333333
        // raw = 0.5 * 0.5 - 0.5 * 0.333333 = 0.083333; raw + (-0.44) = -0.356667
        // Phi(-0.356667) = 0.36067, so Stress = 36.
        #expect(score(window(hr: 62, lnRmssd: 3.45), baseline()) == StressResult(stress: 36, state: .value))
    }

    @Test func lowerHRVRaisesStress() {
        // z_HRV = (3.30 - 3.4) / 0.15 = -0.666667, z_HR = 0.
        // raw = 0.333333; raw + (-0.44) = -0.106667. Phi(-0.106667) = 0.45753, so Stress = 46.
        #expect(score(window(hr: 60, lnRmssd: 3.30), baseline()) == StressResult(stress: 46, state: .value))
    }

    @Test func calibratingBelowSevenQualifyingDays() {
        #expect(score(window(hr: 61), baseline(validDays: 6)) == StressResult(stress: nil, state: .calibrating))
        #expect(score(window(hr: 61), baseline(validDays: 7)).state == .value)
    }

    @Test func exertionTakesPrecedenceOverCalibration() {
        // HRR = (140 - 60) / (180 - 60) = 80 / 120 = 0.667 > 0.40.
        #expect(score(window(hr: 140), baseline(validDays: 0)) == StressResult(stress: nil, state: .exertion))
    }

    @Test func validWindowWithoutHRIsInsufficient() {
        #expect(score(window(hr: nil), baseline()) == StressResult(stress: nil, state: .insufficient))
    }

    @Test func zeroMADUsesTheSigmaFloorInsteadOfBeingInsufficient() {
        // A steady HR baseline has MAD 0. The 4 bpm floor is the sigma, so the value still scores.
        // z_HR = (61 - 60) / 4 = 0.25, z_HRV = 0, raw = 0.125, Stress = round(100 * Phi(-0.315)) = 38.
        let b = StressBaseline(
            validDays: 7, hrMedian: 60, hrMAD: 0, lnRmssdMedian: 3.4, lnRmssdMAD: 0,
            hrOnlyDays: 7, hrOnlyMedian: 60, hrOnlyMAD: 0
        )
        #expect(score(window(hr: 61), b) == StressResult(stress: 38, state: .value))
    }

    @Test func zeroHRVMADUsesTheLnRmssdFloor() {
        // z_HRV uses sigma 0.15 (the floor), so a 0.15 drop is one sigma. z_HR = 0, z_HRV = -1,
        // raw = -0.5 * -1 = 0.5, raw + (-0.44) = 0.06, Stress = round(100 * Phi(0.06)) = 52.
        let b = StressBaseline(
            validDays: 7, hrMedian: 60, hrMAD: 1, lnRmssdMedian: 3.4, lnRmssdMAD: 0,
            hrOnlyDays: 7, hrOnlyMedian: 60, hrOnlyMAD: 1
        )
        #expect(score(window(hr: 60, lnRmssd: 3.25), b) == StressResult(stress: 52, state: .value))
    }

    @Test func missingMedianIsInsufficient() {
        let b = StressBaseline(
            validDays: 7, hrMedian: nil, hrMAD: nil, lnRmssdMedian: 3.4, lnRmssdMAD: 0.06,
            hrOnlyDays: 7, hrOnlyMedian: 60, hrOnlyMAD: 1
        )
        #expect(score(window(hr: 61), b) == StressResult(stress: nil, state: .insufficient))
    }

    @Test func hrOnlyWithoutValidRRUsesHalfTheZScore() {
        // z = (61 - 60) / 4.0 = 0.25. raw = 0.5 * 0.25 = 0.125, Stress = round(100 * Phi(-0.315)) = 38.
        #expect(score(window(hr: 61, valid: false), baseline()) == StressResult(stress: 38, state: .hrOnly))
    }

    @Test func hrOnlyNeedsSevenDaysOfHRDays() {
        #expect(score(window(hr: 61, valid: false), baseline(hrOnlyDays: 6))
            == StressResult(stress: nil, state: .calibrating))
    }

    @Test func bandsFollowUIThresholds() {
        // 0-33 low, 34-66 moderate, 67-100 high.
        #expect(StressBand.of(stress: 0) == .low)
        #expect(StressBand.of(stress: 33) == .low)
        #expect(StressBand.of(stress: 34) == .moderate)
        #expect(StressBand.of(stress: 66) == .moderate)
        #expect(StressBand.of(stress: 67) == .high)
        #expect(StressBand.of(stress: 100) == .high)
    }

    @Test func baselineLookbackCountsOnlyTheFourteenPriorDays() throws {
        // Scored day is 2026-10-08. Lookback days are offsets 1 to 14 days before it.
        // Offsets 1 to 7 have 24 valid awake windows each, so they qualify for R-R (validDays = 7).
        // Offsets 8 to 13 have 23 valid windows and one invalid window. They do not qualify for R-R,
        // but all 24 have HR, so they qualify for the HR-only baseline (hrOnlyDays = 7 + 6 = 13).
        // Offset 15 has 24 valid windows at 150 bpm, and the scored day itself has 24 at 200 bpm. Both must be ignored.
        var windows: [FiveMinuteWindow] = []
        func awakeDay(offset: Int, valid: Int, hr: Double) {
            let start = LocalTime.localTime(LocalTime.adding(days: -offset, to: oct8), hour: 8, in: chicago)
            for j in 0..<24 {
                let isValid = j < valid
                windows.append(FiveMinuteWindow(
                    startMs: start + Int64(j) * 300_000, hrMean: hr, rrCount: 0, rrSumMs: 0, valid: isValid,
                    rmssd: nil, sdnn: nil, lnRmssd: isValid ? 3.4 : nil, baevskySqrt: nil
                ))
            }
        }
        for offset in 1...7 { awakeDay(offset: offset, valid: 24, hr: 60) }
        for offset in 8...13 { awakeDay(offset: offset, valid: 23, hr: 60) }
        awakeDay(offset: 15, valid: 24, hr: 150)
        awakeDay(offset: 0, valid: 24, hr: 200)

        let b = StressBaseline.build(windows: windows, day: oct8, nights: SleepNights(sleep: [], in: chicago), restingHR: 60, maxHR: 180)
        #expect(b.validDays == 7)
        #expect(b.hrOnlyDays == 13)
        // Offsets 15 and 0 are excluded, so the 60 bpm windows are the only values and the median is 60.
        let hrMedian = try #require(b.hrMedian)
        #expect(hrMedian == 60)
    }

    @Test func baselineExcludesExertionWindows() {
        // One awake window at 130 bpm is in exertion (HRR 0.583). It must not count toward the baseline.
        // Without that exclusion, the day would have 24 valid windows and count as qualifying.
        let start = LocalTime.localTime(LocalTime.adding(days: -1, to: oct8), hour: 8, in: chicago)
        var windows = (0..<23).map { j in
            FiveMinuteWindow(
                startMs: start + Int64(j) * 300_000, hrMean: 60, rrCount: 0, rrSumMs: 0, valid: true,
                rmssd: nil, sdnn: nil, lnRmssd: 3.4, baevskySqrt: nil
            )
        }
        windows.append(FiveMinuteWindow(
            startMs: start + 23 * 300_000, hrMean: 130, rrCount: 0, rrSumMs: 0, valid: true,
            rmssd: nil, sdnn: nil, lnRmssd: 3.4, baevskySqrt: nil
        ))
        let b = StressBaseline.build(windows: windows, day: oct8, nights: SleepNights(sleep: [], in: chicago), restingHR: 60, maxHR: 180)
        #expect(b.validDays == 0)
    }

    @Test func sleepWindowsAreExcludedFromTheBaseline() {
        // Two sleeps: one ended on 10-07 morning (began 10-06 23:00) and one began 10-07 22:30 and ended on 10-08.
        // Each has 24 windows at 45 bpm inside it. Those must not count, for either the morning or the evening.
        // Day 10-07 has 24 awake windows at 60 bpm, which must be the whole baseline.
        let sleep = [
            SleepSpan(startMs: chicagoMs(2026, 10, 6, 23, 0), endMs: chicagoMs(2026, 10, 7, 7, 0), isNap: false),
            SleepSpan(startMs: chicagoMs(2026, 10, 7, 22, 30), endMs: chicagoMs(2026, 10, 8, 7, 0), isNap: false),
        ]
        var windows: [FiveMinuteWindow] = []
        func add(from start: Int64, count: Int, hr: Double) {
            for j in 0..<count {
                windows.append(FiveMinuteWindow(
                    startMs: start + Int64(j) * 300_000, hrMean: hr, rrCount: 0, rrSumMs: 0, valid: true,
                    rmssd: nil, sdnn: nil, lnRmssd: 3.4, baevskySqrt: nil
                ))
            }
        }
        add(from: chicagoMs(2026, 10, 7, 2, 0), count: 24, hr: 45)
        add(from: chicagoMs(2026, 10, 7, 23, 0), count: 24, hr: 45)
        add(from: chicagoMs(2026, 10, 7, 8, 0), count: 24, hr: 60)

        let b = StressBaseline.build(
            windows: windows, day: oct8, nights: SleepNights(sleep: sleep, in: chicago), restingHR: 60, maxHR: 180
        )
        #expect(b.validDays == 1)
        #expect(b.hrMedian == 60)
    }

    @Test func fourteenDayHistoryScoresAwakeWindowsAgainstAwakeBaseline() throws {
        // Sleep sits at 62 +/- 3 bpm in 00:00-06:00 (outside the awake baseline). Awake windows sit at 80 +/- 8 bpm
        // in 08:00-22:00. Stress is scored against the awake baseline only.
        var windows: [FiveMinuteWindow] = []
        for offset in 1...14 {
            let day = LocalTime.adding(days: -offset, to: oct8)
            let night = LocalTime.localTime(day, hour: 0, in: chicago)
            let awake = LocalTime.localTime(day, hour: 8, in: chicago)
            for j in 0..<72 {
                let sleepHR = 62 + 3 * sin(Double(j) * 0.9)
                let sleepValid = j % 9 != 0
                windows.append(FiveMinuteWindow(
                    startMs: night + Int64(j) * 300_000, hrMean: sleepHR, rrCount: 0, rrSumMs: 0, valid: sleepValid,
                    rmssd: nil, sdnn: nil, lnRmssd: sleepValid ? 3.9 : nil, baevskySqrt: nil
                ))
            }
            for j in 0..<168 {
                let awakeHR = 80 + 8 * sin(Double(j) * 0.7)
                let lnRmssd = 3.4 + 0.1 * sin(Double(j) * 1.3)
                windows.append(FiveMinuteWindow(
                    startMs: awake + Int64(j) * 300_000, hrMean: awakeHR, rrCount: 0, rrSumMs: 0, valid: true,
                    rmssd: nil, sdnn: nil, lnRmssd: lnRmssd, baevskySqrt: nil
                ))
            }
        }
        let b = StressBaseline.build(windows: windows, day: oct8, nights: SleepNights(sleep: [], in: chicago), restingHR: 60, maxHR: 180)
        #expect(b.validDays == 14)
        let hrMedian = try #require(b.hrMedian)
        let lnMedian = try #require(b.lnRmssdMedian)
        #expect(abs(hrMedian - 80) < 1)

        // A workout-free window at 88 bpm with typical HRV is above the awake median, but nowhere near the
        // sleep baseline (which would put it at z of about 6). It must stay below 80.
        let high = score(FiveMinuteWindow(
            startMs: 0, hrMean: 88, rrCount: 225, rrSumMs: 180_000, valid: true,
            rmssd: nil, sdnn: nil, lnRmssd: lnMedian, baevskySqrt: nil
        ), b)
        #expect(high.state == .value)
        #expect(try #require(high.stress) < 80)

        // At the awake median, the score sits at the centre of the scale, about 33.
        let median = score(FiveMinuteWindow(
            startMs: 0, hrMean: hrMedian, rrCount: 225, rrSumMs: 180_000, valid: true,
            rmssd: nil, sdnn: nil, lnRmssd: lnMedian, baevskySqrt: nil
        ), b)
        #expect(abs(try #require(median.stress) - 33) <= 3)
    }

    private func chicagoMs(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Int64 {
        let localDay = LocalDay(year: year, month: month, day: day)
        return LocalTime.localTime(localDay, hour: hour, in: chicago) + Int64(minute) * LocalTime.msPerMinute
    }
}
