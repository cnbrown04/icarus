import Foundation
import Testing
@testable import Metrics

@Suite("RestingHR (PLAN.md 8.1)")
struct RestingHRTests {
    private let chicago = TimeZone(identifier: "America/Chicago")!
    private let oct8 = LocalDay(year: 2026, month: 10, day: 8)

    private func minute(_ index: Int64, _ hr: Double, n: Int = 60) -> MinuteAggregate {
        MinuteAggregate(minuteMs: index * 60_000, hrAvg: hr, hrMin: 0, hrMax: 0, hrN: n)
    }

    @Test func windowSlidesOneMinuteAtATime() {
        // Per-minute HR: 100, 100, 100, 50, 50, 50, 50, 50.
        // Windows starting at minutes 0, 1, 2, 3 have means 80, 70, 60, 50. The lowest is 50.
        let hr: [Double] = [100, 100, 100, 50, 50, 50, 50, 50]
        let minutes = hr.enumerated().map { minute(Int64($0.offset), $0.element) }
        #expect(RestingHR.lowestWindowMean(minutes, in: 0..<(8 * 60_000)) == 50)
    }

    @Test func minuteWithFortySevenSamplesBreaksTheRun() {
        // Minutes 0 to 7 at 70 bpm with 60 samples each. Minute 2 is at 40 bpm with 47 samples,
        // which is below 0.8 coverage. Runs that contain minute 2 are not eligible.
        // Only the run of minutes 3 to 7 is left, with mean 70.
        var minutes = (0..<8).map { minute(Int64($0), 70) }
        minutes[2] = minute(2, 40, n: 47)
        #expect(RestingHR.lowestWindowMean(minutes, in: 0..<(8 * 60_000)) == 70)
    }

    @Test func fortyEightSamplesCountAsCoverage() {
        // Minutes 0 to 4 at 50 bpm with 47 samples are ineligible. Minutes 10 to 14 at 60 bpm with 48 samples count.
        let low = (0..<5).map { minute(Int64($0), 50, n: 47) }
        let eligible = (10..<15).map { minute(Int64($0), 60, n: 48) }
        #expect(RestingHR.lowestWindowMean(low + eligible, in: 0..<(15 * 60_000)) == 60)
    }

    @Test func runsMustLieInsideTheRange() {
        // Five minutes at 50 bpm, but the range covers only four of them.
        let minutes = (0..<5).map { minute(Int64($0), 50) }
        #expect(RestingHR.lowestWindowMean(minutes, in: 0..<(4 * 60_000)) == nil)
    }

    @Test func fourMinutesIsNoWindow() {
        let minutes = (0..<4).map { minute(Int64($0), 58) }
        #expect(RestingHR.lowestWindowMean(minutes, in: 0..<(10 * 60_000)) == nil)
    }

    @Test func nightUsesLocalMidnightToSix() {
        // Minutes 02:00 to 02:04 local at 55 bpm. The window mean is (55 * 5) / 5 = 55.
        let start = LocalTime.localTime(oct8, hour: 2, in: chicago)
        let minutes = (0..<5).map { MinuteAggregate(minuteMs: start + Int64($0) * 60_000, hrAvg: 55, hrMin: 0, hrMax: 0, hrN: 60) }
        #expect(RestingHR.forNight(of: oct8, minutes: minutes, in: chicago) == 55)
    }

    @Test func minutesFromSixAreOutsideTheNight() {
        // Minutes 05:55 to 05:59 at 66 bpm form the only run inside the night. 06:00 to 06:04 at 45 bpm is outside.
        let at0555 = LocalTime.localTime(oct8, hour: 5, in: chicago) + 55 * 60_000
        let at0600 = LocalTime.localTime(oct8, hour: 6, in: chicago)
        let minutes = (0..<5).map { MinuteAggregate(minuteMs: at0555 + Int64($0) * 60_000, hrAvg: 66, hrMin: 0, hrMax: 0, hrN: 60) }
            + (0..<5).map { MinuteAggregate(minuteMs: at0600 + Int64($0) * 60_000, hrAvg: 45, hrMin: 0, hrMax: 0, hrN: 60) }
        #expect(RestingHR.forNight(of: oct8, minutes: minutes, in: chicago) == 66)
    }

    @Test func springForwardNightEndsAtSixLocal() {
        // On 2026-03-08 the night is 00:00 CST to 06:00 CDT, which is 5 h of absolute time.
        // Minutes at 06:00 CDT (11:00Z) are outside the night, so they do not count.
        let day = LocalDay(year: 2026, month: 3, day: 8)
        let at0600 = LocalTime.localTime(day, hour: 6, in: chicago)
        let minutes = (0..<5).map { MinuteAggregate(minuteMs: at0600 + Int64($0) * 60_000, hrAvg: 40, hrMin: 0, hrMax: 0, hrN: 60) }
        #expect(RestingHR.forNight(of: day, minutes: minutes, in: chicago) == nil)
    }
}
