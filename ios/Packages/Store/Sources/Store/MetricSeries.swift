import Foundation
import GRDB
import Metrics

// MetricSeries.swift: the one read path for every metric the app shows. Each screen reads through here, so a
// number has one definition wherever it appears.
//
// Single sources:
// - Resting HR, HRV and respiratory rate come from the MAIN SLEEP SESSION (`sleep_session`), the same row
//   `mainSleepByDay` picks for Recovery and the vitals. Not the `DaySummary` rollup.
// - Sleep need and carried debt come from the SleepDebt ledger that `coachingInputs` uses, not from
//   `SleepCoaching`'s copy.
// - Asleep time is light + deep + REM, or the in-bed span when the night is unstaged, as `dailyScores` computes it.
// - Stress is the latest scored minute within 10 minutes, else that minute's state.
// - Heart rate is the latest minute within 10 minutes.
// - Day values (weeks, months, six months) read `daily_score` only, one SELECT. Intraday values (the day view)
//   read `minute_metric`.
//
// `daily_score` (schema v11) is a cache of `dailyScores` plus the sources above, rewritten by
// `refreshDailyScores` after each history derivation and at launch. Its rows are rebuilt one local day per write
// transaction, so a long backfill never holds the writer for its whole span.

/// One local day's value for a metric. Nil when the day has no value, which is distinct from zero.
public struct MetricDayValue: Sendable, Equatable {
    public let day: LocalDay
    public let value: Double?
}

/// One local day's heart-rate range, the lowest and highest minute average, in bpm.
public struct HeartRateDayRange: Sendable, Equatable {
    public let day: LocalDay
    public let min: Double
    public let max: Double
}

/// One intraday value at a timestamp: a minute's value, or an hour's total for calories.
public struct MetricPoint: Sendable, Equatable {
    /// Epoch ms UTC. For hourly calories, the start of the local hour.
    public let tsMs: Int64
    public let value: Double
}

/// The latest value for a metric, with when it was measured and a state word where one applies.
public struct MetricReading: Sendable, Equatable {
    public let value: Double?
    /// Epoch ms UTC of the measurement: a sleep session's end, or a minute. Nil for daily values.
    public let atMs: Int64?
    /// Stress only, and recovery only: "value", "calibrating", "exertion", "insufficient", "hr_only", "stale" (a
    /// scored minute older than 10 minutes) or nil. Lets the UI word a missing value instead of guessing why.
    public let state: String?
}

/// One row of `daily_score`. Seconds are whole, recovery is 0 to 100, strain is WHOOP's 0 to 21 scale.
public struct DailyScoreRow: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "daily_score"

    /// 'YYYY-MM-DD'.
    public var localDay: String
    public var recovery: Double?
    public var recoveryCalibrating: Bool?
    public var strain: Double?
    public var sleepPerformance: Double?
    public var asleepSec: Int64?
    public var sleepNeedSec: Int64?
    public var sleepDebtSec: Int64?
    public var restingHR: Double?
    public var rmssdMs: Double?
    public var respRate: Double?
    public var stressAvg: Double?
    public var kcal: Double?
    /// Mean, lowest and highest of the day's minute heart-rate averages, bpm.
    public var hrAvg: Double?
    public var hrMin: Double?
    public var hrMax: Double?
    public var computedAt: Int64

    enum CodingKeys: String, CodingKey {
        case localDay = "local_day"
        case recovery
        case recoveryCalibrating = "recovery_calibrating"
        case strain
        case sleepPerformance = "sleep_performance"
        case asleepSec = "asleep_sec"
        case sleepNeedSec = "sleep_need_sec"
        case sleepDebtSec = "sleep_debt_sec"
        case restingHR = "resting_hr"
        case rmssdMs = "rmssd_ms"
        case respRate = "resp_rate"
        case stressAvg = "stress_avg"
        case kcal
        case hrAvg = "hr_avg"
        case hrMin = "hr_min"
        case hrMax = "hr_max"
        case computedAt = "computed_at"
    }
}

extension Database {
    /// Recomputes and stores `daily_score` for each local day from `first` through `last` (inclusive), using
    /// `dailyScores(day:in:)` and the single sources above. Runs in the caller's transaction. Callers that span many
    /// days should call it once per day in its own write (see `AppDatabase.refreshDailyScores`).
    public func refreshDailyScores(from first: LocalDay, through last: LocalDay, in timeZone: TimeZone, nowMs: Int64) throws {
        for day in Self.days(from: first, through: last) {
            try dailyScoreRow(for: day, in: timeZone, nowMs: nowMs).insert(self, onConflict: .replace)
        }
    }

    /// The day values for `kind` over `from` through `last`, one entry per local day, oldest first. Reads `daily_score`
    /// only. A day with no row, or with a missing value, is nil. Heart rate is the day's mean of minute averages.
    public func metricDays(_ kind: MetricKind, from first: LocalDay, through last: LocalDay, in timeZone: TimeZone) throws -> [MetricDayValue] {
        let days = Self.days(from: first, through: last)
        guard !days.isEmpty else { return [] }
        let column = Self.dailyColumn(kind)
        let rows = try Row.fetchAll(self, sql: """
        SELECT local_day, \(column) AS value FROM daily_score WHERE local_day BETWEEN ? AND ?
        """, arguments: [Self.dayKey(first), Self.dayKey(last)])
        var values: [String: Double] = [:]
        for row in rows {
            if let value: Double = row["value"] {
                values[row["local_day"]] = value
            }
        }
        return days.map { MetricDayValue(day: $0, value: values[Self.dayKey($0)]) }
    }

    /// Each local day's lowest and highest minute heart-rate average from `first` through `last`, oldest first, for a
    /// daily range bar chart. Reads `daily_score` only. Days with no heart-rate minutes are left out.
    public func heartRateRange(from first: LocalDay, through last: LocalDay, in timeZone: TimeZone) throws -> [HeartRateDayRange] {
        let days = Self.days(from: first, through: last)
        guard !days.isEmpty else { return [] }
        let rows = try Row.fetchAll(self, sql: """
        SELECT local_day, hr_min, hr_max FROM daily_score
        WHERE local_day BETWEEN ? AND ? AND hr_min IS NOT NULL AND hr_max IS NOT NULL ORDER BY local_day
        """, arguments: [Self.dayKey(first), Self.dayKey(last)])
        var byKey: [String: HeartRateDayRange] = [:]
        for row in rows {
            let key: String = row["local_day"]
            let lowest: Double = row["hr_min"]
            let highest: Double = row["hr_max"]
            guard let day = days.first(where: { Self.dayKey($0) == key }) else { continue }
            byKey[key] = HeartRateDayRange(day: day, min: lowest, max: highest)
        }
        return days.compactMap { byKey[Self.dayKey($0)] }
    }

    /// The intraday values for `kind` on local `day`, oldest first. Heart rate is each minute's average, stress is
    /// each scored minute, and calories are the kcal summed per local hour. Empty for kinds without intraday values.
    public func metricIntraday(_ kind: MetricKind, day: LocalDay, in timeZone: TimeZone) throws -> [MetricPoint] {
        guard kind.hasIntraday else { return [] }
        let from = LocalTime.localTime(day, hour: 0, in: timeZone)
        let to = LocalTime.localTime(LocalTime.adding(days: 1, to: day), hour: 0, in: timeZone)
        switch kind {
        case .heartRate:
            return try Row.fetchAll(self, sql: """
            SELECT minute_ms, hr_avg FROM minute_metric
            WHERE minute_ms >= ? AND minute_ms < ? AND hr_avg IS NOT NULL ORDER BY minute_ms
            """, arguments: [from, to]).map { MetricPoint(tsMs: $0["minute_ms"], value: $0["hr_avg"] as Double) }
        case .stress:
            return try Row.fetchAll(self, sql: """
            SELECT minute_ms, stress FROM minute_metric
            WHERE minute_ms >= ? AND minute_ms < ? AND stress_state IN (?, ?) AND stress IS NOT NULL ORDER BY minute_ms
            """, arguments: [from, to, StressState.value.rawValue, StressState.hrOnly.rawValue]).map {
                MetricPoint(tsMs: $0["minute_ms"], value: Double($0["stress"] as Int64))
            }
        case .calories:
            let minutes = try Row.fetchAll(self, sql: """
            SELECT minute_ms, kcal FROM minute_metric WHERE minute_ms >= ? AND minute_ms < ? ORDER BY minute_ms
            """, arguments: [from, to])
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            var hourly: [Int: Double] = [:]
            for row in minutes {
                let date = Date(timeIntervalSince1970: Double(row["minute_ms"] as Int64) / 1000)
                hourly[calendar.component(.hour, from: date), default: 0] += row["kcal"] as Double
            }
            return hourly.keys.sorted().map { hour in
                MetricPoint(tsMs: LocalTime.localTime(day, hour: hour, in: timeZone), value: hourly[hour] ?? 0)
            }
        case .restingHR, .hrv, .respiratoryRate, .recovery, .strain, .sleep:
            return []
        }
    }

    /// The latest value for `kind` at `nowMs`. This is the one definition every screen uses.
    ///
    /// - Resting HR, HRV and respiratory rate: the most recent main sleep that ended by `nowMs`, read through the same
    ///   rule as `mainSleepByDay` for its day, so the number equals `metricDays` for that day.
    /// - Stress: the latest scored minute within 10 minutes, else the latest minute's state ("stale" when that
    ///   state is a score older than 10 minutes).
    /// - Heart rate: the latest minute's average within 10 minutes.
    /// - Recovery, strain, sleep and calories: today's `daily_score` row. A missing or older-than-5-minute row is
    ///   rebuilt first. Inside a read-only transaction the rebuilt values are returned without being cached.
    public func metricLatest(_ kind: MetricKind, nowMs: Int64, in timeZone: TimeZone) throws -> MetricReading {
        switch kind {
        case .restingHR, .hrv, .respiratoryRate:
            return try latestMainSleepReading(kind, nowMs: nowMs, in: timeZone)
        case .stress:
            return try latestStressReading(nowMs: nowMs)
        case .heartRate:
            let row = try Row.fetchOne(self, sql: """
            SELECT minute_ms, hr_avg FROM minute_metric
            WHERE hr_avg IS NOT NULL AND minute_ms BETWEEN ? AND ? ORDER BY minute_ms DESC LIMIT 1
            """, arguments: [nowMs - Self.recentWindowMs, nowMs])
            guard let row else { return MetricReading(value: nil, atMs: nil, state: nil) }
            return MetricReading(value: row["hr_avg"], atMs: row["minute_ms"], state: nil)
        case .recovery, .strain, .sleep, .calories:
            return try latestDailyReading(kind, nowMs: nowMs, in: timeZone)
        }
    }

    // MARK: - Internals

    /// How recent a minute must be to count as "latest" for stress and heart rate.
    static let recentWindowMs: Int64 = 10 * LocalTime.msPerMinute
    /// How old a `daily_score` row may be before `metricLatest` rebuilds it.
    static let dailyScoreMaxAgeMs: Int64 = 5 * LocalTime.msPerMinute

    /// The `daily_score` column behind a day value.
    static func dailyColumn(_ kind: MetricKind) -> String {
        switch kind {
        case .recovery: "recovery"
        case .strain: "strain"
        case .sleep: "asleep_sec"
        case .calories: "kcal"
        case .restingHR: "resting_hr"
        case .hrv: "rmssd_ms"
        case .respiratoryRate: "resp_rate"
        case .stress: "stress_avg"
        case .heartRate: "hr_avg"
        }
    }

    /// 'YYYY-MM-DD', the `local_day` key.
    static func dayKey(_ day: LocalDay) -> String {
        func pad(_ value: Int, _ width: Int) -> String {
            let text = String(value)
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        return "\(pad(day.year, 4))-\(pad(day.month, 2))-\(pad(day.day, 2))"
    }

    /// One local day's cache row, from the existing score code and the single sources.
    func dailyScoreRow(for day: LocalDay, in timeZone: TimeZone, nowMs: Int64) throws -> DailyScoreRow {
        let scores = try dailyScores(day: day, in: timeZone)
        let (_, debt) = try sleepDebtLedger(endingOn: day, in: timeZone)
        let carried = max(-debt.balanceSec, 0)
        let need = SleepNeed.adjustedNeedSec(
            baselineNeedSec: SleepNeed.defaultBaselineSec,
            sleepDebtSec: carried,
            dayStrain: scores.strain?.whoopScale
        )
        let night = try mainSleepByDay(from: day, through: day, in: timeZone)[day]
        let summary = try daySummaries([day], in: timeZone).first
        let heartRate = try Row.fetchOne(self, sql: """
        SELECT AVG(hr_avg) AS mean, MIN(hr_avg) AS lowest, MAX(hr_avg) AS highest FROM minute_metric
        WHERE minute_ms >= ? AND minute_ms < ? AND hr_avg IS NOT NULL
        """, arguments: [
            LocalTime.localTime(day, hour: 0, in: timeZone),
            LocalTime.localTime(LocalTime.adding(days: 1, to: day), hour: 0, in: timeZone),
        ])

        var recovery: Double?
        var calibrating: Bool?
        switch scores.recovery {
        case let .scored(score)?:
            recovery = score.score
            calibrating = false
        case .insufficientBaseline?:
            calibrating = true
        case nil:
            break
        }
        return DailyScoreRow(
            localDay: Self.dayKey(day),
            recovery: recovery,
            recoveryCalibrating: calibrating,
            strain: scores.strain?.whoopScale,
            sleepPerformance: scores.sleep?.performancePct,
            asleepSec: scores.sleep.map { Int64($0.asleepSec.rounded()) },
            sleepNeedSec: Int64(need.rounded()),
            sleepDebtSec: Int64(carried.rounded()),
            restingHR: night?.restingHr,
            rmssdMs: night?.rmssdMs,
            respRate: night?.respRateBrpm,
            stressAvg: summary?.stressAverage,
            // A day without heart rate (band not worn) has no calories: its minute rows only carry the resting
            // estimate, which would chart ~1,600 kcal for a day nobody measured.
            kcal: (heartRate?["mean"] as Double?) == nil ? nil : summary?.kcalTotal,
            hrAvg: heartRate?["mean"],
            hrMin: heartRate?["lowest"],
            hrMax: heartRate?["highest"],
            computedAt: nowMs
        )
    }

    private func latestMainSleepReading(_ kind: MetricKind, nowMs: Int64, in timeZone: TimeZone) throws -> MetricReading {
        let latest = try SleepSessionRow.fetchOne(self, sql: """
        SELECT * FROM sleep_session WHERE is_nap = 0 AND end_ms <= ? ORDER BY end_ms DESC, rowid DESC LIMIT 1
        """, arguments: [nowMs])
        guard let latest else { return MetricReading(value: nil, atMs: nil, state: nil) }
        // The session `mainSleepByDay` keeps for its day, which is the one `daily_score` was built from.
        let day = LocalTime.localDay(containing: latest.endMs, in: timeZone)
        let session = try mainSleepByDay(from: day, through: day, in: timeZone)[day] ?? latest
        return MetricReading(value: session.nightlyValue(kind), atMs: session.endMs, state: nil)
    }

    /// Both scored states carry a stress number: `value` (heart rate and HRV) and `hr_only` (heart rate alone, when the
    /// beat-to-beat signal is too thin — most of the day on this band). Reading only `value` hid every hr_only minute.
    private static let scoredStressStates: Set<String> = [StressState.value.rawValue, StressState.hrOnly.rawValue]

    private func latestStressReading(nowMs: Int64) throws -> MetricReading {
        let scored = try Row.fetchOne(self, sql: """
        SELECT minute_ms, stress, stress_state FROM minute_metric
        WHERE stress_state IN (?, ?) AND stress IS NOT NULL AND minute_ms BETWEEN ? AND ? ORDER BY minute_ms DESC LIMIT 1
        """, arguments: [StressState.value.rawValue, StressState.hrOnly.rawValue, nowMs - Self.recentWindowMs, nowMs])
        if let scored {
            return MetricReading(value: Double(scored["stress"] as Int64), atMs: scored["minute_ms"], state: scored["stress_state"])
        }
        let latest = try Row.fetchOne(self, sql: """
        SELECT minute_ms, stress_state FROM minute_metric WHERE minute_ms <= ? ORDER BY minute_ms DESC LIMIT 1
        """, arguments: [nowMs])
        guard let latest else { return MetricReading(value: nil, atMs: nil, state: nil) }
        let state: String = latest["stress_state"]
        return MetricReading(
            value: nil,
            atMs: latest["minute_ms"],
            state: Self.scoredStressStates.contains(state) ? "stale" : state
        )
    }

    private func latestDailyReading(_ kind: MetricKind, nowMs: Int64, in timeZone: TimeZone) throws -> MetricReading {
        let today = LocalTime.localDay(containing: nowMs, in: timeZone)
        var row = try DailyScoreRow.fetchOne(self, sql: "SELECT * FROM daily_score WHERE local_day = ?", arguments: [Self.dayKey(today)])
        if row == nil || (row?.computedAt ?? 0) < nowMs - Self.dailyScoreMaxAgeMs {
            let fresh = try dailyScoreRow(for: today, in: timeZone, nowMs: nowMs)
            // Caching needs a write transaction. A read-only caller still gets the fresh values.
            try? fresh.insert(self, onConflict: .replace)
            row = fresh
        }
        guard let row else { return MetricReading(value: nil, atMs: nil, state: nil) }
        switch kind {
        case .recovery:
            return MetricReading(
                value: row.recovery,
                atMs: nil,
                state: row.recoveryCalibrating == true ? "calibrating" : nil
            )
        case .strain:
            return MetricReading(value: row.strain, atMs: nil, state: nil)
        case .sleep:
            return MetricReading(value: row.asleepSec.map(Double.init), atMs: nil, state: nil)
        default:
            return MetricReading(value: row.kcal, atMs: nil, state: nil)
        }
    }
}

extension AppDatabase {
    /// Refreshes `daily_score` for the `lastDays` local days ending on today, one write transaction per day.
    public func refreshDailyScores(lastDays: Int, nowMs: Int64) async throws {
        guard let timeZone = try await writer.read({ try $0.profile()?.timeZone }) else { return }
        let today = LocalTime.localDay(containing: nowMs, in: timeZone)
        let first = LocalTime.adding(days: -(lastDays - 1), to: today)
        try await refreshDays(Database.days(from: first, through: today), in: timeZone, nowMs: nowMs)
    }

    /// Refreshes `daily_score` for the local days touched by `[fromMs, toMs]`, one write transaction per day.
    public func refreshDailyScores(fromMs: Int64, toMs: Int64, nowMs: Int64) async throws {
        guard toMs >= fromMs, let timeZone = try await writer.read({ try $0.profile()?.timeZone }) else { return }
        let first = LocalTime.localDay(containing: fromMs, in: timeZone)
        let last = LocalTime.localDay(containing: toMs, in: timeZone)
        try await refreshDays(Database.days(from: first, through: last), in: timeZone, nowMs: nowMs)
    }

    /// True when `daily_score` is empty, or holds any row computed before `DailyScoreCache.algoSinceMs`, which means
    /// the score math changed since the cache was last filled.
    public func dailyScoresNeedBackfill() async throws -> Bool {
        try await writer.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM daily_score") ?? 0
            guard count > 0 else { return true }
            let oldest = try Int64.fetchOne(db, sql: "SELECT MIN(computed_at) FROM daily_score") ?? 0
            return oldest < DailyScoreCache.algoSinceMs
        }
    }

    private func refreshDays(_ days: [LocalDay], in timeZone: TimeZone, nowMs: Int64) async throws {
        for day in days {
            try await writer.write { db in
                try db.refreshDailyScores(from: day, through: day, in: timeZone, nowMs: nowMs)
            }
        }
    }
}

/// Settings for the `daily_score` cache.
public enum DailyScoreCache {
    /// How many local days the launch backfill fills.
    public static let backfillDays = 180
    /// Bump to the date of any change to the score math (`dailyScores`, the single sources). Rows computed before
    /// it are rebuilt by the next launch. Nothing else in the cache needs versioning.
    public static let algoSinceMs: Int64 = 1_793_475_180_000
}
