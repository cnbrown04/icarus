import Foundation

/// A calendar date in the user's timezone.
public struct LocalDay: Sendable, Hashable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }
}

/// Wall-clock helpers. Timestamps are epoch ms UTC (PLAN.md 10.1).
public enum LocalTime {
    public static let msPerMinute: Int64 = 60_000
    /// Windows are aligned to UTC multiples of 5 minutes. For timezones with a whole-5-minute
    /// offset this is the same as wall-clock alignment.
    public static let msPerWindow: Int64 = 300_000
    /// Night window is 00:00 to 06:00 local (PLAN.md 8.1, 8.3).
    public static let nightEndHour = 6

    public static func localDay(containing tsMs: Int64, in timeZone: TimeZone) -> LocalDay {
        let parts = calendar(timeZone).dateComponents(
            [.year, .month, .day],
            from: Date(timeIntervalSince1970: Double(tsMs) / 1000)
        )
        return LocalDay(year: parts.year!, month: parts.month!, day: parts.day!)
    }

    /// The calendar day `days` days away. Negative values go back in time.
    /// Pure date arithmetic, so no timezone is involved.
    public static func adding(days: Int, to day: LocalDay) -> LocalDay {
        let shifted = utcCalendar.date(
            from: DateComponents(year: day.year, month: day.month, day: day.day + days, hour: 0)
        )!
        let parts = utcCalendar.dateComponents([.year, .month, .day], from: shifted)
        return LocalDay(year: parts.year!, month: parts.month!, day: parts.day!)
    }

    /// Epoch ms of `hour`:00 local on `day`.
    ///
    /// The offset is resolved by hand instead of with `Calendar.date(from:)`, which returns nil for a
    /// wall-clock time that DST skipped. Two passes settle the offset when a transition falls between
    /// the UTC guess and the answer.
    public static func localTime(_ day: LocalDay, hour: Int, in timeZone: TimeZone) -> Int64 {
        let wall = utcCalendar.date(
            from: DateComponents(year: day.year, month: day.month, day: day.day, hour: hour)
        )!
        let wallMs = Int64((wall.timeIntervalSince1970 * 1000).rounded())
        var instantMs = wallMs - Int64(timeZone.secondsFromGMT(for: wall)) * 1000
        for _ in 0..<2 {
            let instant = Date(timeIntervalSince1970: Double(instantMs) / 1000)
            instantMs = wallMs - Int64(timeZone.secondsFromGMT(for: instant)) * 1000
        }
        return instantMs
    }

    /// Half-open night window [00:00, 06:00) local on `day`.
    public static func nightWindow(of day: LocalDay, in timeZone: TimeZone) -> Range<Int64> {
        localTime(day, hour: 0, in: timeZone)..<localTime(day, hour: nightEndHour, in: timeZone)
    }

    /// Rounds down to a multiple of `size` ms. Correct for negative timestamps.
    public static func roundDown(_ tsMs: Int64, to size: Int64) -> Int64 {
        tsMs - ((tsMs % size) + size) % size
    }

    /// Rounds up to a multiple of `size` ms.
    public static func roundUp(_ tsMs: Int64, to size: Int64) -> Int64 {
        let down = roundDown(tsMs, to: size)
        return down == tsMs ? down : down + size
    }

    /// Multiples of `step` in the half-open range `[lower, upper)`, ascending.
    public static func starts(from lower: Int64, to upper: Int64, step: Int64) -> [Int64] {
        var starts: [Int64] = []
        var current = lower
        while current < upper {
            starts.append(current)
            current += step
        }
        return starts
    }

    private static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
}
