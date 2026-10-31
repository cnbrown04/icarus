import Foundation
import GRDB
import Metrics

/// One local day's strain, recovery, sleep coaching and regularity, computed from stored data (Metrics
/// `Strain`, `Recovery`, `SleepCoaching` and `SleepRegularity`).
///
/// These are labelled proxies built from published methods. They are not WHOOP's Strain, Recovery or Sleep
/// Performance, whose models are proprietary. Each optional value is nil when its inputs are too thin to
/// trust, rather than filled with a guess.
public struct DailyScores: Sendable, Equatable {
    public let day: LocalDay
    /// Strain for `day` from its whole-day minutes, or nil when the day fails `Strain`'s gates or has no resting HR.
    public let strain: DayStrain?
    /// Recovery from the main sleep that ended on `day`, against the prior nights. Nil when no main sleep ended
    /// on `day` or that sleep lacks HRV or resting HR. `.insufficientBaseline` is a real outcome, not an error:
    /// the UI shows the calibration count it carries.
    public let recovery: Recovery.Outcome?
    /// Sleep coaching for the main sleep that ended on `day`, over the 14 days to `day`. Nil when no main
    /// sleep ended on `day`: an older night's performance must not stand in for today's.
    /// Its `dayStrain` is the whoop-scale strain of `day - 1`.
    public let sleep: SleepCoachingSummary?
    /// Respiratory rate of the main sleep that ended on `day`, breaths/min. Nil when R-R could not support it.
    public let respiratoryRateBrpm: Double?
    /// True when a stimulant window was active at the main sleep's start or in the hour before it. False when no
    /// main sleep ended on `day`. A factual flag for the Sleep and Recovery notes, not a score input.
    public let stimulantNearSleepOnset: Bool
    /// Phillips SRI over the 7 local days ending on `day`, in [-100, 100]. Nil with fewer than two days of data.
    public let sleepRegularityIndex: Double?
    /// Bed and wake consistency over the 7 local days ending on `day`, 0...1 where 1 is most regular. Nil with
    /// fewer than two main sleeps in that window.
    public let sleepConsistency: Double?
}

/// A day's strain on both scales the app shows.
public struct DayStrain: Sendable, Equatable {
    /// Effort on 0...100 (Metrics `Strain.score`, Banister TRIMP; see `Database.strainMethod`).
    public let effort: Double
    /// The same value on WHOOP's 0...21 Day Strain axis (`Strain.whoopStrain(fromEffort:)`). A display mapping.
    public let whoopScale: Double
}

extension Database {
    /// Scores for local `day`, read in one transaction so the numbers share a snapshot.
    ///
    /// Strain uses `day`'s minutes and its night's resting HR, and HRmax comes from the profile (a
    /// user-entered value, else Tanaka from birth year). Recovery uses the main sleep that ended on `day`
    /// and one entry per local day for the previous 60 days (oldest first, never `day`'s own). Sleep coaching and
    /// regularity use the sessions of the trailing 14 and 7 local days; naps count toward them as `isNap`.
    public func dailyScores(day: LocalDay, in timeZone: TimeZone) throws -> DailyScores {
        let profile = try profile()
        let maxHR = profile.flatMap { Self.maxHR(of: $0, year: day.year) }
        let sex = profile?.formula ?? .male

        let dayStart = LocalTime.localTime(day, hour: 0, in: timeZone)
        let dayEnd = LocalTime.localTime(LocalTime.adding(days: 1, to: day), hour: 0, in: timeZone)
        let previousDay = LocalTime.adding(days: -1, to: day)

        let strain = try wholeDayStrain(day, maxHR: maxHR, sex: sex, in: timeZone)
        let previousStrain = try wholeDayStrain(previousDay, maxHR: maxHR, sex: sex, in: timeZone)

        // The 14-day window feeds coaching; its 7-day tail feeds regularity. Both include naps.
        let fourteenStart = LocalTime.localTime(LocalTime.adding(days: -13, to: day), hour: 0, in: timeZone)
        let sevenStart = LocalTime.localTime(LocalTime.adding(days: -6, to: day), hour: 0, in: timeZone)
        let recentRows = try SleepSessionRow.fetchAll(self, sql: """
        SELECT * FROM sleep_session WHERE end_ms >= ? AND end_ms < ? ORDER BY start_ms, rowid
        """, arguments: [fourteenStart, dayEnd])
        let recent = try recentRows.map { try sleepNight($0) }

        let sleepSummary = SleepCoaching.summarize(
            nights: recent,
            dayStrain: previousStrain?.whoopScale,
            baselineNeedSec: SleepNeed.defaultBaselineSec,
            timeZone: timeZone
        )
        let weekNights = recent.filter { $0.endSec * 1000 >= sevenStart }

        // Tonight is the longest main sleep that ended on `day`, as `SleepNights` picks it.
        let tonight = recentRows
            .filter { !$0.isNap && $0.endMs >= dayStart && $0.endMs < dayEnd }
            .max { $0.endMs - $0.startMs < $1.endMs - $1.startMs }
        var recovery: Recovery.Outcome?
        if let tonight {
            recovery = try recoveryOutcome(
                for: tonight,
                day: day,
                sleepPerformance: sleepSummary.map { $0.performancePct / 100 },
                in: timeZone
            )
        }

        var stimulantNearSleep = false
        if let tonight {
            stimulantNearSleep = try stimulantNearSleepOnset(sleepStartMs: tonight.startMs, in: timeZone)
        }

        return DailyScores(
            day: day,
            strain: strain,
            recovery: recovery,
            sleep: tonight == nil ? nil : sleepSummary,
            respiratoryRateBrpm: tonight?.respRateBrpm,
            stimulantNearSleepOnset: stimulantNearSleep,
            sleepRegularityIndex: SleepRegularity.phillipsSRI(nights: weekNights, timeZone: timeZone),
            sleepConsistency: SleepRegularity.consistencyScore(nights: weekNights, timeZone: timeZone)
        )
    }

    // MARK: - Strain

    /// Strain method for the shown score: Banister. Edwards zones (NOOP's default) start at 50 % heart-rate
    /// reserve, so an ordinary day of walking and sitting scores exactly 0 — the real 2026-10-22 peaked at a
    /// 125 bpm minute against a 127 bpm zone-1 floor. NOOP #1545 names the same blind spot, and OpenStrap's
    /// `load_trimp.dart` dropped its Edwards copy (audit MOT-06). Banister is exponential in %HRR with only a
    /// sedentary floor subtracted.
    static let strainMethod: Strain.Method = .banister

    /// `day`'s strain, or nil when HRmax or any resting HR is unknown, or `Strain` refuses the day.
    ///
    /// Resting HR is the day's night, else the most recent main sleep's: a day whose night is missing (no
    /// data, or not slept) still has a fully measured day, and resting HR moves slowly enough to borrow.
    private func wholeDayStrain(_ day: LocalDay, maxHR: Double?, sex: FormulaSex, in timeZone: TimeZone) throws -> DayStrain? {
        let from = LocalTime.localTime(day, hour: 0, in: timeZone)
        let to = LocalTime.localTime(LocalTime.adding(days: 1, to: day), hour: 0, in: timeZone)
        let latestRestingHR = try Double.fetchOne(self, sql: """
        SELECT resting_hr FROM sleep_session
        WHERE is_nap = 0 AND resting_hr IS NOT NULL AND end_ms < ? ORDER BY end_ms DESC LIMIT 1
        """, arguments: [to])
        guard let maxHR, let restingHR = try restingHeartRate(night: day, in: timeZone) ?? latestRestingHR else {
            return nil
        }
        let minutes = try minuteMetricRows(from: from, to: to).compactMap(\.minuteAggregate)
        guard let score = Strain.score(minutes: minutes, restingHR: restingHR, maxHR: maxHR, method: Self.strainMethod, sex: sex) else {
            return nil
        }
        return DayStrain(effort: score.strain, whoopScale: Strain.whoopStrain(fromEffort: score.strain))
    }

    /// HRmax as `Dashboard` takes it: user-entered, else Tanaka from birth year.
    private static func maxHR(of profile: ProfileRow, year: Int) -> Double? {
        if let hrMax = profile.hrMax {
            return Double(hrMax)
        }
        guard let birthYear = profile.birthYear else { return nil }
        return HeartRateZones.maxHR(userEntered: nil, ageYears: max(0, year - birthYear))
    }

    // MARK: - Recovery

    /// How many local days before `day` the recovery baseline looks back over.
    static let recoveryHistoryDays = 60

    /// Recovery for tonight's session against the `recoveryHistoryDays` local days before `day`, one entry
    /// per day (that day's longest main sleep, nil when there was none), oldest first. Per DAY rather than
    /// per stored session, so a missing night reads as missing to the baseline fold (its stale rule) and a
    /// months-old night is outside the window, not "the previous night". Nil when tonight lacks HRV or
    /// resting HR, the two values the score cannot do without.
    private func recoveryOutcome(
        for tonight: SleepSessionRow,
        day: LocalDay,
        sleepPerformance: Double?,
        in timeZone: TimeZone
    ) throws -> Recovery.Outcome? {
        guard let hrv = tonight.rmssdMs, let restingHR = tonight.restingHr else { return nil }
        let firstDay = LocalTime.adding(days: -Self.recoveryHistoryDays, to: day)
        let fromMs = LocalTime.localTime(firstDay, hour: 0, in: timeZone)
        let toMs = LocalTime.localTime(day, hour: 0, in: timeZone)
        // Earlier days only: tonight in the history would pull the baseline toward the value being judged.
        let rows = try SleepSessionRow.fetchAll(self, sql: """
        SELECT * FROM sleep_session WHERE is_nap = 0 AND end_ms >= ? AND end_ms < ? ORDER BY end_ms
        """, arguments: [fromMs, toMs])
        var byDay: [LocalDay: SleepSessionRow] = [:]
        for row in rows {
            let key = LocalTime.localDay(containing: row.endMs, in: timeZone)
            if let kept = byDay[key], kept.durationS >= row.durationS { continue }
            byDay[key] = row
        }
        let history = (0..<Self.recoveryHistoryDays).map { offset in
            byDay[LocalTime.adding(days: offset, to: firstDay)]
        }
        return Recovery.score(Recovery.Input(
            hrv: hrv,
            restingHR: restingHR,
            respiratoryRate: tonight.respRateBrpm,
            sleepPerformance: sleepPerformance,
            hrvHistory: history.map { $0?.rmssdMs },
            restingHRHistory: history.map { $0?.restingHr },
            respiratoryRateHistory: history.map { $0?.respRateBrpm }
        ))
    }

    // MARK: - Sleep blocks

    /// A stored session as a Metrics sleep block. Asleep time is light + deep + REM when the night is staged,
    /// else the in-bed span, which is the same headline `Dashboard.SleepSnapshot.Night.asleepS` shows.
    private func sleepNight(_ row: SleepSessionRow) throws -> SleepNight {
        let segments = try sleepStageSegmentRows(bandID: row.bandID, sessionStartMs: row.startMs)
        var asleepSec = Double(row.durationS)
        if !segments.isEmpty {
            asleepSec = segments.reduce(0.0) { total, segment in
                guard let stage = segment.stageValue, stage != .wake else { return total }
                return total + Double(max(0, segment.endMs - segment.startMs)) / 1000
            }
        }
        return SleepNight(
            startSec: row.startMs / 1000,
            endSec: row.endMs / 1000,
            asleepSec: asleepSec,
            isNap: row.isNap
        )
    }
}
