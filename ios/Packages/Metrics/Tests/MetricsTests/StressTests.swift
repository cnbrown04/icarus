import Foundation
import Testing
@testable import Metrics

@Suite("Stress: baseline and score (PLAN.md 8.3)")
struct StressTests {
    private let chicago = TimeZone(identifier: "America/Chicago")!
    private let oct8 = LocalDay(year: 2026, month: 10, day: 8)

    /// Median HR 60 (MAD 1), median lnRMSSD 3.4 (MAD 0.06), both calibrated unless the caller says otherwise.
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

    @Test func zeroDeviationIsFifty() {
        // z_HR = 0 and z_HRV = 0, so S = 0 and Phi(0) = 0.5. Stress = round(50) = 50.
        #expect(score(window(hr: 60), baseline()) == StressResult(stress: 50, state: .value))
    }

    @Test func valueMatchesHandComputedScore() {
        // z_HR  = (61 - 60) / (1.4826 * 1.0)      = 1 / 1.4826     = 0.674491
        // z_HRV = (ln 3.45 - 3.4) / (1.4826 * 0.06) = 0.05 / 0.088956 = 0.562107
        // S = 0.5 * 0.674491 - 0.5 * 0.562107 = 0.056192
        // Phi(0.056192) = 0.522405, so 100 * Phi = 52.24 and Stress = 52.
        #expect(score(window(hr: 61, lnRmssd: 3.45), baseline()) == StressResult(stress: 52, state: .value))
    }

    @Test func lowerHRVRaisesStress() {
        // z_HRV = (3.34 - 3.4) / 0.088956 = -0.674491, the same size as z_HR above but with the other sign.
        // S = 0.5 * 0 - 0.5 * (-0.674491) = 0.337245. Phi(0.337245) = 0.632 and Stress = 63.
        #expect(score(window(hr: 60, lnRmssd: 3.34), baseline()) == StressResult(stress: 63, state: .value))
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

    @Test func zeroMADIsInsufficientForThatComponent() {
        // MAD_HR = 0 makes z_HR undefined. R-R is present, so the state is insufficient and not hr_only.
        let b = StressBaseline(
            validDays: 7, hrMedian: 60, hrMAD: 0, lnRmssdMedian: 3.4, lnRmssdMAD: 0.06,
            hrOnlyDays: 7, hrOnlyMedian: 60, hrOnlyMAD: 1
        )
        #expect(score(window(hr: 61), b) == StressResult(stress: nil, state: .insufficient))
    }

    @Test func zeroHRVMADIsInsufficient() {
        let b = StressBaseline(
            validDays: 7, hrMedian: 60, hrMAD: 1, lnRmssdMedian: 3.4, lnRmssdMAD: 0,
            hrOnlyDays: 7, hrOnlyMedian: 60, hrOnlyMAD: 1
        )
        #expect(score(window(hr: 61), b) == StressResult(stress: nil, state: .insufficient))
    }

    @Test func hrOnlyWithoutValidRR() {
        // z = (61 - 60) / (1.4826 * 1.0) = 0.674491 = Phi^-1(0.75), so 100 * Phi = 75.00003 and Stress = 75.
        #expect(score(window(hr: 61, valid: false), baseline()) == StressResult(stress: 75, state: .hrOnly))
    }

    @Test func hrOnlyNeedsSevenDaysOfHRNights() {
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

    @Test func baselineLookbackCountsOnlyTheFourteenPriorNights() throws {
        // Scored day is 2026-10-08. Lookback nights are offsets 1 to 14 days before it.
        // Offsets 1 to 7 have 12 valid night windows each, so they qualify for R-R (validDays = 7).
        // Offsets 8 to 13 have 11 valid windows and one invalid window. They do not qualify for R-R,
        // but all 12 have HR, so they qualify for the HR-only baseline (hrOnlyDays = 7 + 6 = 13).
        // Offset 15 has 12 valid windows at 150 bpm, and the scored day itself has 12 at 200 bpm. Both must be ignored.
        var windows: [FiveMinuteWindow] = []
        func nights(offset: Int, valid: Int, hr: Double) {
            let start = LocalTime.localTime(LocalTime.adding(days: -offset, to: oct8), hour: 0, in: chicago)
            for j in 0..<12 {
                let isValid = j < valid
                windows.append(FiveMinuteWindow(
                    startMs: start + Int64(j) * 300_000, hrMean: hr, rrCount: 0, rrSumMs: 0, valid: isValid,
                    rmssd: nil, sdnn: nil, lnRmssd: isValid ? 3.4 : nil, baevskySqrt: nil
                ))
            }
        }
        for offset in 1...7 { nights(offset: offset, valid: 12, hr: 60) }
        for offset in 8...13 { nights(offset: offset, valid: 11, hr: 60) }
        nights(offset: 15, valid: 12, hr: 150)
        nights(offset: 0, valid: 12, hr: 200)

        let b = StressBaseline.build(windows: windows, day: oct8, in: chicago, restingHR: 60, maxHR: 180)
        #expect(b.validDays == 7)
        #expect(b.hrOnlyDays == 13)
        // Offsets 15 and 0 are excluded, so the 60 bpm nights are the only values and the median is 60.
        let hrMedian = try #require(b.hrMedian)
        #expect(hrMedian == 60)
    }

    @Test func baselineExcludesExertionNights() {
        // One night window at 130 bpm is in exertion (HRR 0.583). It must not count toward the baseline.
        // Without that exclusion, the day would have 12 valid windows and count as qualifying.
        let start = LocalTime.localTime(LocalTime.adding(days: -1, to: oct8), hour: 0, in: chicago)
        var windows = (0..<11).map { j in
            FiveMinuteWindow(
                startMs: start + Int64(j) * 300_000, hrMean: 60, rrCount: 0, rrSumMs: 0, valid: true,
                rmssd: nil, sdnn: nil, lnRmssd: 3.4, baevskySqrt: nil
            )
        }
        windows.append(FiveMinuteWindow(
            startMs: start + 11 * 300_000, hrMean: 130, rrCount: 0, rrSumMs: 0, valid: true,
            rmssd: nil, sdnn: nil, lnRmssd: 3.4, baevskySqrt: nil
        ))
        let b = StressBaseline.build(windows: windows, day: oct8, in: chicago, restingHR: 60, maxHR: 180)
        #expect(b.validDays == 0)
    }
}
