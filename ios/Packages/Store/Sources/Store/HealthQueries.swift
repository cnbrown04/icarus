import Foundation
import GRDB
import Metrics

// Health read paths: per-day score series for Trends and Recovery, and nightly vitals against the user's own
// 30-night range (Health Monitor). Everything is derived from `sleep_session`, `minute_metric` and
// `historical_record` at read time. Nothing is stored, and no migration is involved. Local only.

/// One local day's numbers for the Health screens. Every value is nil when its inputs are missing or too thin.
public struct DailyScorePoint: Sendable, Equatable {
    public let day: LocalDay
    /// Recovery 0...100 (labelled proxy, `Recovery.Score.score`). Nil while calibrating or with no main sleep.
    public let recovery: Double?
    /// Tonight's HRV, nightly RMSSD in ms, from the main sleep that ended on `day`.
    public let hrvMs: Double?
    /// Tonight's resting HR in bpm, from the same main sleep.
    public let restingHR: Double?
    /// Respiratory rate of the main sleep, breaths/min.
    public let respiratoryRate: Double?
    /// Sleep performance of the main sleep, 0...100.
    public let sleepPerformance: Double?
    /// Day strain on WHOOP's 0...21 scale (`DayStrain.whoopScale`).
    public let dayStrain: Double?
    /// Mean of the day's per-minute stress values, 0...100.
    public let stressAverage: Double?
}

/// The nightly vitals for one day and the 30-night personal range each is judged against.
public struct VitalsBaseline: Sendable, Equatable {
    public let day: LocalDay
    /// Tonight's value per vital. Skin temperature is the nightly mean of `skin_temp_raw` (raw units).
    public let tonight: [HealthMonitor.Vital: Double]
    /// The range per vital. A vital is absent when fewer than `HealthMonitor.minimumNights` prior nights have a value.
    public let baselines: [HealthMonitor.Vital: HealthMonitor.Baseline]
    /// Main sleeps in the `HealthMonitor.baselineNights` days before `day`, whether or not each has every vital.
    public let priorNights: Int

    /// Tonight judged against the ranges. See `HealthMonitor.evaluate`.
    public var statuses: [HealthMonitor.Status] {
        HealthMonitor.evaluate(tonight: tonight, baseline: baselines)
    }
}

extension Database {
    /// Per-day scores for every local day from `first` through `last` (inclusive), oldest first.
    ///
    /// Cost: recovery, sleep coaching and strain come from `dailyScores(day:in:)`, which reads the day's
    /// minutes and a 60-day recovery history, roughly 20 small queries per day. A 90-day series is the slow
    /// path, so callers load the widest span once and slice it rather than re-reading per span. Stress is
    /// batched through `daySummaries` (one minute-metric read), and HRV, RHR and respiratory rate come from
    /// one sleep-session read.
    public func dailyScoreSeries(from first: LocalDay, through last: LocalDay, in timeZone: TimeZone) throws -> [DailyScorePoint] {
        let days = Self.days(from: first, through: last)
        guard !days.isEmpty else { return [] }
        let mainSleeps = try mainSleepByDay(from: first, through: last, in: timeZone)
        var stressByDay: [LocalDay: Double] = [:]
        for summary in try daySummaries(days, in: timeZone) {
            if let stress = summary.stressAverage { stressByDay[summary.day] = stress }
        }
        var points: [DailyScorePoint] = []
        points.reserveCapacity(days.count)
        for day in days {
            let scores = try dailyScores(day: day, in: timeZone)
            var recovery: Double?
            if case let .scored(score)? = scores.recovery {
                recovery = score.score
            }
            let night = mainSleeps[day]
            points.append(DailyScorePoint(
                day: day,
                recovery: recovery,
                hrvMs: night?.rmssdMs,
                restingHR: night?.restingHr,
                respiratoryRate: night?.respRateBrpm,
                sleepPerformance: scores.sleep?.performancePct,
                dayStrain: scores.strain?.whoopScale,
                stressAverage: stressByDay[day]
            ))
        }
        return points
    }

    /// Tonight's vitals for `day` and the range each is judged against: the main sleep that ended on `day`
    /// versus the `HealthMonitor.baselineNights` days before it. Tonight is never in its own range.
    ///
    /// Reads one sleep-session range, plus one `historical_record` average per session for skin temperature.
    /// Nightly RHR, HRV and respiratory rate come from the sessions, the same values Recovery uses.
    public func vitalsBaseline(day: LocalDay, in timeZone: TimeZone) throws -> VitalsBaseline {
        let first = LocalTime.adding(days: -HealthMonitor.baselineNights, to: day)
        let mainSleeps = try mainSleepByDay(from: first, through: day, in: timeZone)

        var nightly: [HealthMonitor.Vital: [Double]] = [:]
        var priorNights = 0
        for offset in 1...HealthMonitor.baselineNights {
            guard let row = mainSleeps[LocalTime.adding(days: -offset, to: day)] else { continue }
            priorNights += 1
            for (vital, value) in try Self.vitals(of: row, skinTemp: nightlySkinTemp(row)) {
                nightly[vital, default: []].append(value)
            }
        }

        var tonight: [HealthMonitor.Vital: Double] = [:]
        if let row = mainSleeps[day] {
            for (vital, value) in try Self.vitals(of: row, skinTemp: nightlySkinTemp(row)) {
                tonight[vital] = value
            }
        }
        var baselines: [HealthMonitor.Vital: HealthMonitor.Baseline] = [:]
        for vital in HealthMonitor.Vital.allCases {
            if let range = HealthMonitor.baseline(for: vital, nightly: nightly[vital] ?? []) {
                baselines[vital] = range
            }
        }
        return VitalsBaseline(day: day, tonight: tonight, baselines: baselines, priorNights: priorNights)
    }

    // MARK: - Helpers

    /// Main sleeps (longest non-nap session) keyed by the local day they END on. Same rule as
    /// `dailyScores`, so Recovery, the score series and the monitor all read the same night.
    func mainSleepByDay(from first: LocalDay, through last: LocalDay, in timeZone: TimeZone) throws -> [LocalDay: SleepSessionRow] {
        let from = LocalTime.localTime(first, hour: 0, in: timeZone)
        let to = LocalTime.localTime(LocalTime.adding(days: 1, to: last), hour: 0, in: timeZone)
        let rows = try SleepSessionRow.fetchAll(self, sql: """
        SELECT * FROM sleep_session WHERE is_nap = 0 AND end_ms >= ? AND end_ms < ? ORDER BY end_ms, rowid
        """, arguments: [from, to])
        var byDay: [LocalDay: SleepSessionRow] = [:]
        for row in rows {
            let key = LocalTime.localDay(containing: row.endMs, in: timeZone)
            if let kept = byDay[key], kept.durationS >= row.durationS { continue }
            byDay[key] = row
        }
        return byDay
    }

    /// Mean raw skin-temperature byte over one session's records. Nil when the session has none.
    private func nightlySkinTemp(_ row: SleepSessionRow) throws -> Double? {
        try Double.fetchOne(self, sql: """
        SELECT AVG(skin_temp_raw) FROM historical_record
        WHERE band_id = ? AND ts_ms >= ? AND ts_ms < ? AND skin_temp_raw IS NOT NULL
        """, arguments: [row.bandID, row.startMs, row.endMs])
    }

    /// The vitals one session carries, skipping any that are missing.
    private static func vitals(of row: SleepSessionRow, skinTemp: Double?) -> [(HealthMonitor.Vital, Double)] {
        var values: [(HealthMonitor.Vital, Double)] = []
        if let value = row.restingHr { values.append((.restingHR, value)) }
        if let value = row.rmssdMs { values.append((.hrv, value)) }
        if let value = row.respRateBrpm { values.append((.respiratoryRate, value)) }
        if let value = skinTemp { values.append((.skinTemp, value)) }
        return values
    }

    /// Every local day from `first` through `last`, oldest first. Empty when `last` is before `first`.
    static func days(from first: LocalDay, through last: LocalDay) -> [LocalDay] {
        func key(_ day: LocalDay) -> Int { day.year * 10_000 + day.month * 100 + day.day }
        var out: [LocalDay] = []
        var cursor = first
        while key(cursor) <= key(last) {
            out.append(cursor)
            cursor = LocalTime.adding(days: 1, to: cursor)
        }
        return out
    }
}
