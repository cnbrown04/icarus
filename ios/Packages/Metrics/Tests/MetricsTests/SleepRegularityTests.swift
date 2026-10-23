import Foundation
import Testing
@testable import Metrics

@Suite("SleepRegularity (Phillips SRI and bed/wake consistency)")
struct SleepRegularityTests {
    private let chicago = TimeZone(identifier: "America/Chicago")!

    /// Unix seconds for `minute` past local midnight on the given October 2026 day.
    private func unix(day: Int, minute: Int) -> Int64 {
        LocalTime.localTime(LocalDay(year: 2026, month: 10, day: day), hour: 0, in: chicago) / 1000 + Int64(minute) * 60
    }

    /// A block from one local clock time to another. Minutes are counted from midnight of each day.
    private func block(from start: (day: Int, minute: Int), to end: (day: Int, minute: Int), nap: Bool = false) -> SleepNight {
        let s = unix(day: start.day, minute: start.minute)
        let e = unix(day: end.day, minute: end.minute)
        return SleepNight(startSec: s, endSec: e, asleepSec: Double(e - s), isNap: nap)
    }

    /// A 23:00 to 07:00 night that wakes on `wakeDay`.
    private func standardNight(wakeDay: Int) -> SleepNight {
        block(from: (wakeDay - 1, 23 * 60), to: (wakeDay, 7 * 60))
    }

    // MARK: - Phillips SRI

    @Test func identicalNightsGiveHundred() throws {
        let nights = (12...16).map { standardNight(wakeDay: $0) }
        let sri = try #require(SleepRegularity.phillipsSRI(nights: nights, timeZone: chicago))
        #expect(abs(sri - 100) < 1e-9)
    }

    @Test func antiAlignedNightsGiveTheFormulaFloor() throws {
        // Day 12 is asleep 00:00 to 08:00 and awake the rest of the day. Day 13 is awake 00:00 to 08:00
        // and asleep 08:00 to 24:00. Every epoch differs, so agreement is zero and SRI is -100.
        let nights = [
            block(from: (12, 0), to: (12, 8 * 60)),
            block(from: (13, 8 * 60), to: (14, 0)),
        ]
        let sri = try #require(SleepRegularity.phillipsSRI(nights: nights, timeZone: chicago))
        #expect(abs(sri - (-100)) < 1e-9)
    }

    @Test func partialAgreementMatchesTheEpochCount() throws {
        // Day 12 is asleep 00:00 to 08:00. Day 13 is asleep 00:00 to 12:00 and 23:00 to 24:00.
        // Over the 1440 epochs of the pair, agreement is 480 (both asleep at 00:00 to 08:00) plus 660
        // (both awake at 12:00 to 23:00), for 1140. SRI = 200 * 1140 / 1440 - 100 = 58.33.
        let nights = [
            block(from: (12, 0), to: (12, 8 * 60)),
            block(from: (13, 0), to: (13, 12 * 60)),
            block(from: (13, 23 * 60), to: (14, 0)),
        ]
        let sri = try #require(SleepRegularity.phillipsSRI(nights: nights, timeZone: chicago))
        #expect(abs(sri - 58.333333) < 0.001)
    }

    @Test func noNightsGiveNil() {
        #expect(SleepRegularity.phillipsSRI(nights: [], timeZone: chicago) == nil)
    }

    @Test func oneNightGivesNil() {
        // One night spans two local days, but the observed epochs on those days do not overlap, so no
        // pair can be compared.
        #expect(SleepRegularity.phillipsSRI(nights: [standardNight(wakeDay: 13)], timeZone: chicago) == nil)
    }

    // MARK: - Bed and wake consistency

    @Test func identicalBedAndWakeTimesGiveOne() throws {
        let nights = (12...14).map { standardNight(wakeDay: $0) }
        let score = try #require(SleepRegularity.consistencyScore(nights: nights, timeZone: chicago))
        #expect(abs(score - 1) < 1e-6)
    }

    @Test func bedtimesAcrossMidnightAreCloseNotFar() throws {
        // Bedtimes alternate 23:30 and 00:30 with the same 07:00 wake. Bedtimes are one hour apart, so the
        // circular spread is 30.04 min. The wake spread is zero, so the score is 1 - 15.02 / 120 = 0.875.
        // A linear SD over clock minutes would instead read 23:30 and 00:30 as 23 h apart.
        let bedMinutes = [23 * 60 + 30, 30, 23 * 60 + 30, 30]
        let nights = bedMinutes.enumerated().map { index, bed -> SleepNight in
            let wakeDay = 12 + index
            let bedDay = bed > 12 * 60 ? wakeDay - 1 : wakeDay
            return block(from: (bedDay, bed), to: (wakeDay, 7 * 60))
        }
        let score = try #require(SleepRegularity.consistencyScore(nights: nights, timeZone: chicago))
        #expect(abs(score - 0.875) < 0.01)
    }

    @Test func twoHourBedtimeSpreadScoresLowerThanIdentical() throws {
        // Bedtimes of 23:00 and 01:00 give a bed spread of about 60.4 min, which averages to about 30.2
        // min with the zero wake spread. The score is 1 - 30.2 / 120 = 0.75.
        let irregular = [
            block(from: (11, 23 * 60), to: (12, 7 * 60)),
            block(from: (13, 60), to: (13, 7 * 60)),
        ]
        let regular = (12...13).map { standardNight(wakeDay: $0) }
        let irregularScore = try #require(SleepRegularity.consistencyScore(nights: irregular, timeZone: chicago))
        let regularScore = try #require(SleepRegularity.consistencyScore(nights: regular, timeZone: chicago))
        #expect(abs(irregularScore - 0.75) < 0.01)
        #expect(irregularScore < regularScore)
    }

    @Test func napsDoNotAffectConsistency() throws {
        let nights = [standardNight(wakeDay: 12), standardNight(wakeDay: 13)]
        let withNap = nights + [block(from: (13, 14 * 60), to: (13, 15 * 60), nap: true)]
        let plain = try #require(SleepRegularity.consistencyScore(nights: nights, timeZone: chicago))
        let napped = try #require(SleepRegularity.consistencyScore(nights: withNap, timeZone: chicago))
        #expect(abs(plain - napped) < 1e-9)
    }

    @Test func oneNightGivesNilConsistency() {
        #expect(SleepRegularity.consistencyScore(nights: [standardNight(wakeDay: 12)], timeZone: chicago) == nil)
        #expect(SleepRegularity.consistencyScore(nights: [], timeZone: chicago) == nil)
    }
}
