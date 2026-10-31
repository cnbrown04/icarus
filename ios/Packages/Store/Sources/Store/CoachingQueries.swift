import Foundation
import GRDB
import Metrics

// CoachingQueries.swift: the stored inputs for the Strain tab's coaching cards (Strain Coach, Sleep Planner,
// Weekly Assessment). Read-only. No tables or migrations: everything is derived from `sleep_session`,
// `sleep_stage_segment`, `alarm` and the existing daily scores, and is local-only.

/// The wake time the Sleep Planner aims at, and where it came from.
public struct WakePlan: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// The next enabled alarm, within 24 h. `label` is the user's name for it, possibly empty.
        case alarm(label: String)
        /// No alarm inside 24 h, so the median wake time of the last `nights` main sleeps.
        case medianOfRecentWakes(nights: Int)
    }

    /// Unix seconds.
    public let wakeSec: Int64
    public let source: Source
}

/// Everything the coaching cards read, from one snapshot.
public struct CoachingInputs: Equatable, Sendable {
    /// The local day the inputs describe.
    public let day: LocalDay
    /// Today's strain so far on WHOOP's 0 to 21 axis. Nil when the day has too little data to score.
    public let todayStrain: Double?
    /// Recovery 0 to 100 for the main sleep that ended today. Nil when it is calibrating or there was no night.
    public let recoveryPercent: Double?
    /// The population baseline need, 8 h (`SleepNeed.defaultBaselineSec`).
    public let baselineNeedSec: Double
    /// Debt carried into tonight, in seconds (>= 0), from the ledger through the last night.
    public let carriedDebtSec: Double
    /// Tonight's need: baseline + carried debt + today's strain bonus, clamped to 6 to 11 h (`SleepNeed`).
    public let tonightNeedSec: Double
    /// Typical latency and efficiency from recent staged nights, or the defaults.
    public let timing: SleepPlanner.Timing
    /// The planned wake time. Nil when there is no alarm within 24 h and no main sleep to take a median from.
    public let wake: WakePlan?
}

/// Seven full local days ending yesterday, and the seven before them. Oldest first in each.
public struct WeeklyDays: Equatable, Sendable {
    public let thisWeek: [WeeklyAssessment.Day]
    public let previousWeek: [WeeklyAssessment.Day]
}

extension Database {
    /// Inputs for the coaching cards at `nowMs`, read in one snapshot.
    public func coachingInputs(nowMs: Int64, in timeZone: TimeZone) throws -> CoachingInputs {
        let today = LocalTime.localDay(containing: nowMs, in: timeZone)
        let scores = try dailyScores(day: today, in: timeZone)
        let todayStrain = scores.strain?.whoopScale
        let baseline = SleepNeed.defaultBaselineSec
        let (rows, debt) = try sleepDebtLedger(endingOn: today, in: timeZone)
        let carried = max(-debt.balanceSec, 0)
        let tonightNeed = SleepNeed.adjustedNeedSec(
            baselineNeedSec: baseline,
            sleepDebtSec: carried,
            dayStrain: todayStrain
        )

        var latencies: [Double] = []
        var efficiencies: [Double] = []
        for row in rows.filter({ !$0.isNap }).suffix(7) {
            guard let timing = try Self.stagedTiming(row, in: self) else { continue }
            latencies.append(timing.latencySec)
            efficiencies.append(timing.efficiency)
        }

        return CoachingInputs(
            day: today,
            todayStrain: todayStrain,
            recoveryPercent: Self.recoveryPercent(scores.recovery),
            baselineNeedSec: baseline,
            carriedDebtSec: carried,
            tonightNeedSec: tonightNeed,
            timing: SleepPlanner.timing(latenciesSec: latencies, efficiencies: efficiencies),
            wake: try plannedWake(nowMs: nowMs, in: timeZone)
        )
    }

    /// The wake time tonight's sleep should end at. The next enabled alarm within 24 h wins. Otherwise it is
    /// the median local wake time of the last seven main sleeps, next occurring after `nowMs`.
    public func plannedWake(nowMs: Int64, in timeZone: TimeZone) throws -> WakePlan? {
        let horizonMs = nowMs + 24 * 3_600_000
        let alarmWakes: [(ms: Int64, label: String)] = try alarms().compactMap { row in
            guard row.enabled, let schedule = Schedule(json: row.schedule) else { return nil }
            guard let ms = Self.nextOccurrenceMs(
                hour: schedule.hour, minute: schedule.minute, weekdays: schedule.weekdays,
                after: nowMs, in: timeZone
            ), ms <= horizonMs else { return nil }
            return (ms, row.label)
        }
        if let next = alarmWakes.min(by: { $0.ms < $1.ms }) {
            return WakePlan(wakeSec: next.ms / 1000, source: .alarm(label: next.label))
        }

        let recent = try SleepSessionRow.fetchAll(self, sql: """
        SELECT * FROM sleep_session WHERE is_nap = 0 AND end_ms < ? ORDER BY end_ms DESC LIMIT 7
        """, arguments: [nowMs])
        let minutesOfDay = recent.map { row -> Double in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let parts = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: Double(row.endMs) / 1000))
            return Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
        }
        guard let median = SleepPlanner.median(minutesOfDay) else { return nil }
        let rounded = Int(median.rounded())
        guard let ms = Self.nextOccurrenceMs(
            hour: rounded / 60, minute: rounded % 60, weekdays: [], after: nowMs, in: timeZone
        ) else { return nil }
        return WakePlan(wakeSec: ms / 1000, source: .medianOfRecentWakes(nights: recent.count))
    }

    /// The last fourteen local days of daily values, split into the seven full days before `today` and the
    /// seven before those. The week runs to yesterday so no partial day is compared.
    public func weeklyDays(nowMs: Int64, in timeZone: TimeZone) throws -> WeeklyDays {
        let today = LocalTime.localDay(containing: nowMs, in: timeZone)
        let thisWeek = (1...7).reversed().map { LocalTime.adding(days: -$0, to: today) }
        let previousWeek = (8...14).reversed().map { LocalTime.adding(days: -$0, to: today) }
        // HRV and resting HR from each day's main sleep: the values Recovery, Vitals and the metric pages show.
        let mainSleeps = try mainSleepByDay(from: previousWeek[0], through: thisWeek[thisWeek.count - 1], in: timeZone)
        func days(_ list: [LocalDay]) throws -> [WeeklyAssessment.Day] {
            try list.map { day in
                let scores = try dailyScores(day: day, in: timeZone)
                return WeeklyAssessment.Day(
                    recovery: Self.recoveryPercent(scores.recovery),
                    sleepPerformance: scores.sleep?.performancePct,
                    hoursSlept: scores.sleep.map { $0.asleepSec / 3600 },
                    strain: scores.strain?.whoopScale,
                    hrv: mainSleeps[day]?.rmssdMs,
                    restingHR: mainSleeps[day]?.restingHr
                )
            }
        }
        return WeeklyDays(thisWeek: try days(thisWeek), previousWeek: try days(previousWeek))
    }

    // MARK: - Internals

    /// The sleep sessions of the 14 local days ending on `day` (oldest first, naps included) and the SleepDebt
    /// ledger over them. This is the one source for tonight's need and carried debt: `coachingInputs` and the
    /// `daily_score` cache both read it, so the Sleep tab and the metric screens show the same numbers.
    func sleepDebtLedger(endingOn day: LocalDay, in timeZone: TimeZone) throws -> (rows: [SleepSessionRow], debt: SleepDebtLedger) {
        // Sleep that ended on or before `day`'s wake day, which is last night. Tonight ends tomorrow.
        let fourteenStart = LocalTime.localTime(LocalTime.adding(days: -13, to: day), hour: 0, in: timeZone)
        let throughDay = LocalTime.localTime(LocalTime.adding(days: 1, to: day), hour: 0, in: timeZone)
        let rows = try SleepSessionRow.fetchAll(self, sql: """
        SELECT * FROM sleep_session WHERE end_ms >= ? AND end_ms < ? ORDER BY start_ms, rowid
        """, arguments: [fourteenStart, throughDay])
        let nights = try rows.map { try Self.sleepNight($0, in: self) }
        let debt = SleepDebt.ledger(nights: nights, needSec: SleepNeed.defaultBaselineSec, timeZone: timeZone)
        return (rows, debt)
    }

    /// The 0 to 100 recovery, nil when the outcome is calibrating or absent.
    static func recoveryPercent(_ outcome: Recovery.Outcome?) -> Double? {
        guard case let .scored(score)? = outcome else { return nil }
        return score.score
    }

    /// A session as a Metrics block. Asleep is light + deep + REM when staged, else the in-bed span, matching
    /// `DailyScores`.
    static func sleepNight(_ row: SleepSessionRow, in db: Database) throws -> SleepNight {
        let segments = try db.sleepStageSegments(bandID: row.bandID, sessionStartMs: row.startMs)
        var asleepSec = Double(row.durationS)
        if !segments.isEmpty {
            asleepSec = segments.reduce(0.0) { total, segment in
                segment.stage == .wake ? total : total + Double(segment.durationSeconds)
            }
        }
        return SleepNight(startSec: row.startMs / 1000, endSec: row.endMs / 1000, asleepSec: asleepSec, isNap: row.isNap)
    }

    /// Latency and efficiency for one staged night. Nil when the night has no stages.
    static func stagedTiming(_ row: SleepSessionRow, in db: Database) throws -> (latencySec: Double, efficiency: Double)? {
        let segments = try db.sleepStageSegments(bandID: row.bandID, sessionStartMs: row.startMs)
        guard !segments.isEmpty else { return nil }
        let stagedSec = segments.reduce(0.0) { $0 + Double($1.durationSeconds) }
        guard stagedSec > 0 else { return nil }
        let asleepSec = segments.reduce(0.0) { $1.stage == .wake ? $0 : $0 + Double($1.durationSeconds) }
        guard let firstAsleep = segments.first(where: { $0.stage != .wake }) else { return nil }
        let latency = max(0, Double(firstAsleep.startUnix - row.startMs / 1000))
        return (latency, min(1, max(0, asleepSec / stagedSec)))
    }

    /// The wire form of `AlarmSchedule`: `{"time":"06:30","weekdays":[1,2,3,4,5]}`. Store does not depend on
    /// AlarmKitBridge, so the two-field shape is decoded here.
    struct Schedule: Equatable, Sendable {
        let hour: Int
        let minute: Int
        let weekdays: [Int]

        /// Nil for a missing or malformed schedule, so the alarm is skipped rather than guessed at.
        init?(json: String?) {
            guard let json, let data = json.data(using: .utf8),
                  let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
            let parts = wire.time.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
                  let hour = Int(parts[0]), let minute = Int(parts[1]),
                  (0...23).contains(hour), (0...59).contains(minute) else { return nil }
            self.hour = hour
            self.minute = minute
            self.weekdays = wire.weekdays.filter { (1...7).contains($0) }
        }

        private struct Wire: Decodable {
            let time: String
            let weekdays: [Int]
        }
    }

    /// The first instant after `nowMs` on a matching local day at `hour:minute`, as epoch ms. An empty weekday list
    /// matches every day, as `AlarmPlanner.nextOccurrence` does. Searches eight days, so one pass finds a match.
    static func nextOccurrenceMs(hour: Int, minute: Int, weekdays: [Int], after nowMs: Int64, in timeZone: TimeZone) -> Int64? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let now = Date(timeIntervalSince1970: Double(nowMs) / 1000)
        let startOfToday = calendar.startOfDay(for: now)
        for offset in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startOfToday) else { continue }
            if !weekdays.isEmpty, !weekdays.contains(isoWeekday(day, calendar)) { continue }
            guard let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                  candidate > now else { continue }
            return Int64((candidate.timeIntervalSince1970 * 1000).rounded())
        }
        return nil
    }

    /// ISO weekday, 1 = Monday ... 7 = Sunday.
    static func isoWeekday(_ date: Date, _ calendar: Calendar) -> Int {
        let weekday = calendar.component(.weekday, from: date)
        return weekday == 1 ? 7 : weekday - 1
    }
}
