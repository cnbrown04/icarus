import Foundation

/// Next fire times for schedule rules (PLAN.md 9.5). Pure, so it runs on Linux.
public enum AlarmPlanner {
    /// The first time strictly after `now` that matches `schedule`, in `timeZone`.
    ///
    /// DST: a wall-clock time that does not exist on its day (spring forward) resolves to the next valid time, which
    /// is what Calendar does. A time that happens twice (fall back) resolves to its first instant.
    public static func nextOccurrence(
        of schedule: AlarmSchedule,
        after now: Date,
        in timeZone: TimeZone = .current
    ) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let startOfToday = calendar.startOfDay(for: now)
        // Eight days cover every weekday, so one pass finds the match even when today's time has passed.
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startOfToday) else { continue }
            if !schedule.weekdays.isEmpty, !schedule.weekdays.contains(isoWeekday(of: day, in: calendar)) {
                continue
            }
            guard let candidate = calendar.date(
                bySettingHour: schedule.hour,
                minute: schedule.minute,
                second: 0,
                of: day
            ), candidate > now else { continue }
            return candidate
        }
        return nil
    }

    /// The earliest next fire among `rules`. The band has one alarm slot (PLAN.md 9.5), so only the earliest matters.
    public static func earliest(
        _ rules: [AlarmSchedule],
        after now: Date,
        in timeZone: TimeZone = .current
    ) -> Date? {
        rules.compactMap { nextOccurrence(of: $0, after: now, in: timeZone) }.min()
    }

    /// ISO weekday: 1 = Monday ... 7 = Sunday. Calendar numbers Sunday as 1.
    public static func isoWeekday(of date: Date, in calendar: Calendar) -> Int {
        let calendarWeekday = calendar.component(.weekday, from: date)
        return calendarWeekday == 1 ? 7 : calendarWeekday - 1
    }
}
