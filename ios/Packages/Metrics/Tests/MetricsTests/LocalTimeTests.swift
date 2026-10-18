import Foundation
import Testing
@testable import Metrics

@Suite("LocalTime: local days, night windows, rounding")
struct LocalTimeTests {
    private let chicago = TimeZone(identifier: "America/Chicago")!
    private let oct8 = LocalDay(year: 2026, month: 10, day: 8)

    @Test func localMidnightInChicagoIsFiveUTC() {
        // 2026-10-08 is still on CDT (UTC-5), so 00:00 local is 05:00Z.
        // 2026-10-08T05:00:00Z is epoch second 1791435600, so the ms value is 1791435600000.
        #expect(LocalTime.localTime(oct8, hour: 0, in: chicago) == 1_791_435_600_000)
    }

    @Test func nightWindowIsSixHoursOnAnOrdinaryDay() {
        // 06:00 CDT is 11:00Z = 1791457200000. 1791457200000 - 1791435600000 = 21600000 ms = 6 h.
        let night = LocalTime.nightWindow(of: oct8, in: chicago)
        #expect(night.upperBound - night.lowerBound == 21_600_000)
    }

    @Test func nightWindowIsFiveHoursOnSpringForwardDay() {
        // 2026-03-08 jumps from 02:00 CST to 03:00 CDT. 00:00 CST is 06:00Z and 06:00 CDT is 11:00Z.
        // The absolute span is 5 h = 18000000 ms, not 6 h.
        let night = LocalTime.nightWindow(of: LocalDay(year: 2026, month: 3, day: 8), in: chicago)
        #expect(night.upperBound - night.lowerBound == 18_000_000)
    }

    @Test func localDayFollowsTheZone() {
        // 1791435600000 is 00:00 CDT on Oct 8. One ms earlier is 23:59:59.999 CDT on Oct 7.
        #expect(LocalTime.localDay(containing: 1_791_435_600_000, in: chicago) == oct8)
        #expect(LocalTime.localDay(containing: 1_791_435_599_999, in: chicago) == LocalDay(year: 2026, month: 10, day: 7))
    }

    @Test func addingDaysCrossesMonthBoundaries() {
        // 2026 is not a leap year: Feb has 28 days, so Mar 1 minus 1 day is Feb 28.
        // Oct 25 plus 14 days: 6 days to Oct 31, then 8 more into November, which is Nov 8.
        #expect(LocalTime.adding(days: -1, to: LocalDay(year: 2026, month: 3, day: 1))
            == LocalDay(year: 2026, month: 2, day: 28))
        #expect(LocalTime.adding(days: 14, to: LocalDay(year: 2026, month: 10, day: 25))
            == LocalDay(year: 2026, month: 11, day: 8))
    }

    @Test func midnightSkippedByDSTDoesNotTrap() throws {
        // America/Santiago moves its clocks from 00:00 to 01:00 on Sunday 2026-09-06, so that midnight does not exist.
        // The result must be a real instant near the skipped time: 04:00Z (CLT) or 03:00Z (CLST), both within 1 h.
        let santiago = try #require(TimeZone(identifier: "America/Santiago"))
        let utcMidnight = Int64(try #require(ISO8601DateFormatter().date(from: "2026-09-06T00:00:00Z")).timeIntervalSince1970 * 1000)
        let value = LocalTime.localTime(LocalDay(year: 2026, month: 9, day: 6), hour: 0, in: santiago)
        #expect(value >= utcMidnight + 3 * 3_600_000 && value <= utcMidnight + 4 * 3_600_000)
    }

    @Test func roundingHandlesNegativeTimestamps() {
        // -1 ms lies in the minute that starts at -60000. 60001 rounds up to 120000.
        #expect(LocalTime.roundDown(-1, to: 60_000) == -60_000)
        #expect(LocalTime.roundDown(119_999, to: 60_000) == 60_000)
        #expect(LocalTime.roundUp(60_001, to: 60_000) == 120_000)
        #expect(LocalTime.roundUp(60_000, to: 60_000) == 60_000)
    }

    @Test func startsAreHalfOpen() {
        #expect(LocalTime.starts(from: 0, to: 10, step: 3) == [0, 3, 6, 9])
        #expect(LocalTime.starts(from: 5, to: 5, step: 1).isEmpty)
    }
}
