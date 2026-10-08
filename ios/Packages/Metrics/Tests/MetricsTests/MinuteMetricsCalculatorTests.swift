import Foundation
import Testing
@testable import Metrics

@Suite("MinuteMetricsCalculator (PLAN.md 8.1 to 8.4, 10.2)")
struct MinuteMetricsCalculatorTests {
    private let profile = UserProfile(sex: .male, ageYears: 40, heightCm: 180, weightKg: 80)
    private let calibrated = StressBaseline(
        validDays: 7, hrMedian: 60, hrMAD: 1, lnRmssdMedian: 3.4, lnRmssdMAD: 0.06,
        hrOnlyDays: 7, hrOnlyMedian: 60, hrOnlyMAD: 1
    )

    private func context(restingHR: Double? = 60, maxHR: Double = 190) -> MinuteMetricsContext {
        MinuteMetricsContext(profile: profile, restingHR: restingHR, maxHR: maxHR, baseline: calibrated)
    }

    /// 60 samples at `bpm`, one per second, starting at `start`.
    private func minuteSamples(start: Int64, bpm: Int) -> [HeartRateSample] {
        (0..<60).map { HeartRateSample(tsMs: start + Int64($0) * 1_000, bpm: bpm, contact: .detected) }
    }

    @Test func oneRowPerMinuteInRange() {
        let rows = MinuteMetricsCalculator.rows(range: 0..<180_000, samples: [], rr: [], context: context())
        #expect(rows.map(\.minuteMs) == [0, 60_000, 120_000])
    }

    @Test func gapMinuteIsBMREstimated() {
        // No samples in minute 0. Kcal = BMR per minute = 1730 / 1440 = 1.201389. Active kcal = 0. Estimated = true.
        // With no HR and no R-R, the window state is insufficient.
        let row = MinuteMetricsCalculator.rows(range: 0..<60_000, samples: [], rr: [], context: context())[0]
        #expect(row.hrAvg == nil)
        #expect(row.hrN == 0)
        #expect(abs(row.kcal - 1730.0 / 1440.0) < 1e-12)
        #expect(row.activeKcal == 0)
        #expect(row.kcalEstimated)
        #expect(row.stressState == .insufficient)
        #expect(row.stress == nil)
    }

    @Test func aboveFlexUsesKeytel() {
        // RHR 60 and HRmax 190 give HR_flex = 60 + 0.3 * 130 = 99. HR 120 is above that, so Keytel applies.
        // Keytel gives 44.5831 kJ/min = 10.655617 kcal/min (see CaloriesTests).
        let row = MinuteMetricsCalculator.rows(
            range: 0..<60_000, samples: minuteSamples(start: 0, bpm: 120), rr: [], context: context()
        )[0]
        #expect(abs(row.kcal - 44.5831 / 4.184) < 1e-9)
        #expect(!row.kcalEstimated)
    }

    @Test func unknownRestingHRUsesTheNinetyFloor() {
        // With RHR 60 the flex is 99, so 95 bpm would be charged at BMR.
        // With RHR unknown the flex is 90, so 95 bpm uses Keytel:
        // kJ = -55.0969 + 0.6309 * 95 + 0.1988 * 80 + 0.2017 * 40 = 28.8106, kcal = 28.8106 / 4.184 = 6.885899.
        let samples = minuteSamples(start: 0, bpm: 95)
        let known = MinuteMetricsCalculator.rows(range: 0..<60_000, samples: samples, rr: [], context: context())[0]
        let unknown = MinuteMetricsCalculator.rows(
            range: 0..<60_000, samples: samples, rr: [], context: context(restingHR: nil)
        )[0]
        #expect(abs(known.kcal - 1730.0 / 1440.0) < 1e-12)
        #expect(abs(unknown.kcal - 6.885899) < 1e-6)
    }

    @Test func hrvComesFromTheContainingWindow() {
        // 226 intervals alternate 790 and 810 from 0 ms, which makes window 0 valid with RMSSD 20.
        // Minute 0 and minute 4 are in window 0, so they carry RMSSD 20. Minute 5 is in window 1, which has no R-R.
        let rr = (0..<226).map { RRSample(tsMs: Int64($0) * 1_000, rrMs: $0 % 2 == 0 ? 790 : 810) }
        let rows = MinuteMetricsCalculator.rows(
            range: 0..<360_000, samples: minuteSamples(start: 0, bpm: 70), rr: rr, context: context()
        )
        #expect(rows[0].rmssdMs == 20)
        #expect(rows[4].rmssdMs == 20)
        #expect(rows[5].rmssdMs == nil)
        // Window 0 mean HR is 70, HRR = 10 / 130 = 0.077, so it is not exertion.
        // z_HR = 10 / 1.4826 = 6.745 and z_HRV = (ln 20 - 3.4) / 0.088956 = -4.545. S = 5.645, so Stress = 100.
        #expect(rows[0].stressState == .value)
        #expect(rows[0].stress == 100)
    }
}
