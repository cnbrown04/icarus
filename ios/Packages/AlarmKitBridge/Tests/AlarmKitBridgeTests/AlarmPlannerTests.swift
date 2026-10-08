import Foundation
import Testing
@testable import AlarmKitBridge

struct AlarmPlannerTests {
    static let chicago = TimeZone(identifier: "America/Chicago")!
    static let newYork = TimeZone(identifier: "America/New_York")!

    static func instant(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    static func schedule(_ time: String, _ weekdays: [Int] = []) -> AlarmSchedule {
        let parts = time.split(separator: ":").map { Int($0)! }
        return AlarmSchedule(hour: parts[0], minute: parts[1], weekdays: weekdays)!
    }

    @Test func dailyRuleTakesTheNextDayWhenTodaysTimeHasPassed() {
        // 2026-10-07 14:30Z is 09:30 CDT, after 06:30 has passed.
        let next = AlarmPlanner.nextOccurrence(
            of: Self.schedule("06:30", [1, 2, 3, 4, 5, 6, 7]),
            after: Self.instant("2026-10-07T14:30:00Z"),
            in: Self.chicago
        )
        #expect(next == Self.instant("2026-10-08T11:30:00Z"))
    }

    @Test func weekdayRuleSkipsTheWeekend() {
        // 2026-10-10 is a Saturday. The next Monday is 2026-10-12.
        let next = AlarmPlanner.nextOccurrence(
            of: Self.schedule("06:30", [1, 2, 3, 4, 5]),
            after: Self.instant("2026-10-10T15:00:00Z"),
            in: Self.chicago
        )
        #expect(next == Self.instant("2026-10-12T11:30:00Z"))
    }

    @Test func aTimeThatIsExactlyNowDoesNotCountAsNext() {
        let next = AlarmPlanner.nextOccurrence(
            of: Self.schedule("06:30"),
            after: Self.instant("2026-10-08T11:30:00Z"),
            in: Self.chicago
        )
        #expect(next == Self.instant("2026-10-09T11:30:00Z"))
    }

    @Test func oneOffRuleIsTheNextOccurrenceOfAnyDay() {
        let next = AlarmPlanner.nextOccurrence(
            of: Self.schedule("06:30"),
            after: Self.instant("2026-10-08T12:00:00Z"),
            in: Self.chicago
        )
        #expect(next == Self.instant("2026-10-09T11:30:00Z"))
    }

    @Test func sameWallClockTimeMeansDifferentInstantsInDifferentZones() {
        let rule = Self.schedule("06:30")
        let now = Self.instant("2026-10-07T14:30:00Z")
        #expect(AlarmPlanner.nextOccurrence(of: rule, after: now, in: Self.chicago) == Self.instant("2026-10-08T11:30:00Z"))
        #expect(AlarmPlanner.nextOccurrence(of: rule, after: now, in: Self.newYork) == Self.instant("2026-10-08T10:30:00Z"))
    }

    @Test func springForwardGapResolvesToTheFirstValidTimeAfterIt() {
        // 2026-03-08 02:30 does not exist in Chicago. The clock jumps from 02:00 CST to 03:00 CDT at 08:00Z.
        // Calendar picks the first valid instant or a later one within the hour, depending on the platform.
        let next = AlarmPlanner.nextOccurrence(
            of: Self.schedule("02:30"),
            after: Self.instant("2026-03-07T18:00:00Z"),
            in: Self.chicago
        )
        let gapEnd = Self.instant("2026-03-08T08:00:00Z")
        let oneHourLater = Self.instant("2026-03-08T09:00:00Z")
        #expect(next != nil)
        #expect(next.map { $0 >= gapEnd && $0 < oneHourLater } == true)
    }

    @Test func fallBackRepeatedTimeResolvesToItsFirstInstant() {
        // 2026-11-01 01:30 happens twice in Chicago. The first is CDT, 06:30Z.
        let next = AlarmPlanner.nextOccurrence(
            of: Self.schedule("01:30"),
            after: Self.instant("2026-10-31T17:00:00Z"),
            in: Self.chicago
        )
        #expect(next == Self.instant("2026-11-01T06:30:00Z"))
    }

    @Test func earliestPicksTheNearestRuleForTheBand() {
        let now = Self.instant("2026-10-08T12:00:00Z")
        let earliest = AlarmPlanner.earliest(
            [Self.schedule("15:00", [1]), Self.schedule("06:30")],
            after: now,
            in: Self.chicago
        )
        #expect(earliest == Self.instant("2026-10-09T11:30:00Z"))
        #expect(AlarmPlanner.earliest([], after: now, in: Self.chicago) == nil)
    }

    @Test func isoWeekdayCountsMondayAsOneAndSundayAsSeven() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.chicago
        #expect(AlarmPlanner.isoWeekday(of: Self.instant("2026-10-12T17:00:00Z"), in: calendar) == 1)
        #expect(AlarmPlanner.isoWeekday(of: Self.instant("2026-10-11T17:00:00Z"), in: calendar) == 7)
    }
}
