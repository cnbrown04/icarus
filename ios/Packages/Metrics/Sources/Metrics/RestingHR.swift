import Foundation

/// Resting heart rate per local night (PLAN.md 8.1). A proxy until sleep detection exists.
public enum RestingHR {
    public static let windowMinutes = 5
    /// Every minute in the run must have coverage >= 0.8 (at least 48 of 60 samples).
    public static let minCoverage = 0.8

    /// Lowest mean of `hrAvg` over 5 consecutive minutes.
    ///
    /// Each minute must lie inside `range` and have coverage >= 0.8. Windows slide one minute at a
    /// time, so they are not aligned to 5-minute boundaries. Minutes absent from `minutes` break a run.
    /// Nil when no run qualifies.
    public static func lowestWindowMean(_ minutes: [MinuteAggregate], in range: Range<Int64>) -> Double? {
        var eligible: [Int64: Double] = [:]
        for minute in minutes where range.contains(minute.minuteMs) && minute.coverage >= minCoverage {
            eligible[minute.minuteMs] = minute.hrAvg
        }
        let step = LocalTime.msPerMinute
        var lowest: Double?
        for start in eligible.keys {
            let keys = (0..<windowMinutes).map { start + Int64($0) * step }
            guard keys.allSatisfy({ eligible[$0] != nil }) else { continue }
            let mean = keys.reduce(0.0) { $0 + eligible[$1]! } / Double(windowMinutes)
            lowest = lowest.map { Swift.min($0, mean) } ?? mean
        }
        return lowest
    }

    /// RHR for the local night of `day`, 00:00 to 06:00 in `timeZone`.
    public static func forNight(of day: LocalDay, minutes: [MinuteAggregate], in timeZone: TimeZone) -> Double? {
        lowestWindowMean(minutes, in: LocalTime.nightWindow(of: day, in: timeZone))
    }
}
