import Foundation
import Testing
@testable import Metrics

@Suite("SleepNights: the night that belongs to each local day")
struct SleepNightsTests {
    private let chicago = TimeZone(identifier: "America/Chicago")!
    private let oct8 = LocalDay(year: 2026, month: 10, day: 8)

    private func ms(_ day: LocalDay, _ hour: Int) -> Int64 {
        LocalTime.localTime(day, hour: hour, in: chicago)
    }

    @Test func theNightIsTheMainSleepThatEndsOnThatDay() {
        // 23:00 Oct 7 to 07:00 Oct 8 ends on Oct 8, so it is Oct 8's night.
        let sleep = SleepSpan(startMs: ms(LocalTime.adding(days: -1, to: oct8), 23), endMs: ms(oct8, 7), isNap: false)
        let nights = SleepNights(sleep: [sleep], in: chicago)
        #expect(nights.window(of: oct8) == sleep.startMs..<sleep.endMs)
        #expect(nights.isDetected(oct8))
    }

    @Test func aDayWithNoSleepFallsBackToSixAM() {
        let nights = SleepNights(sleep: [], in: chicago)
        #expect(nights.window(of: oct8) == LocalTime.nightWindow(of: oct8, in: chicago))
        #expect(nights.isDetected(oct8) == false)
    }

    @Test func aSleepThatEndsOnAnotherDayDoesNotAnchorThisOne() {
        // Oct 7's main sleep ends Oct 7, so Oct 8 has no detected night and falls back.
        let sleep = SleepSpan(
            startMs: ms(LocalTime.adding(days: -2, to: oct8), 23),
            endMs: ms(LocalTime.adding(days: -1, to: oct8), 7),
            isNap: false
        )
        let nights = SleepNights(sleep: [sleep], in: chicago)
        #expect(nights.window(of: oct8) == LocalTime.nightWindow(of: oct8, in: chicago))
        #expect(nights.window(of: LocalTime.adding(days: -1, to: oct8)) == sleep.startMs..<sleep.endMs)
    }

    @Test func napsNeverAnchorANight() {
        let nap = SleepSpan(startMs: ms(oct8, 13), endMs: ms(oct8, 14), isNap: true)
        let nights = SleepNights(sleep: [nap], in: chicago)
        #expect(nights.window(of: oct8) == LocalTime.nightWindow(of: oct8, in: chicago))
        #expect(nights.isDetected(oct8) == false)
    }

    @Test func theLongerMainSleepWinsWhenTwoEndTheSameDay() {
        // A stale short row beside its extension: both end Oct 8, so the longer one is the night.
        let short = SleepSpan(startMs: ms(oct8, 1), endMs: ms(oct8, 5), isNap: false)
        let long = SleepSpan(startMs: ms(LocalTime.adding(days: -1, to: oct8), 23), endMs: ms(oct8, 7), isNap: false)
        #expect(SleepNights(sleep: [short, long], in: chicago).window(of: oct8) == long.startMs..<long.endMs)
        #expect(SleepNights(sleep: [long, short], in: chicago).window(of: oct8) == long.startMs..<long.endMs)
    }
}
