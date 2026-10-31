import Foundation
import GRDB
import Metrics
import Store

/// Read models for the data screens (PLAN.md §14 rows 7-11). Each `load` runs inside one read so the
/// numbers on a screen come from the same snapshot.
enum Dashboard {
    /// The profile's zone, or the default when no profile exists yet.
    /// The device zone, used before a profile exists.
    static var fallbackZone: TimeZone { .current }

    /// Stress bars are 15-minute averages on every screen that shows them.
    static let stressBucketMs: Int64 = 15 * LocalTime.msPerMinute

    /// HRmax for zones and calorie inputs: user-entered, else Tanaka from birth year (PLAN.md 8.1).
    static func maxHR(_ profile: ProfileRow, year: Int) -> Double? {
        if let hrMax = profile.hrMax {
            return Double(hrMax)
        }
        guard let birthYear = profile.birthYear else { return nil }
        return HeartRateZones.maxHR(userEntered: nil, ageYears: max(0, year - birthYear))
    }

    /// Profile, zone, last night's resting HR and HRmax. Shared by every screen.
    struct Context: Sendable {
        let profile: ProfileRow?
        let timeZone: TimeZone
        let nowMs: Int64
        let restingHR: Double?
        let maxHR: Double?

        static func load(_ db: Database, nowMs: Int64) throws -> Context {
            let profile = try db.profile()
            let zone = profile?.timeZone ?? fallbackZone
            let night = NightWindow.latestCompleted(nowMs: nowMs, in: zone)
            let year = LocalTime.localDay(containing: nowMs, in: zone).year
            return Context(
                profile: profile,
                timeZone: zone,
                nowMs: nowMs,
                restingHR: try db.restingHeartRate(night: night, in: zone),
                maxHR: profile.flatMap { Dashboard.maxHR($0, year: year) }
            )
        }

        var today: LocalDay {
            LocalTime.localDay(containing: nowMs, in: timeZone)
        }
    }

    /// Seven local days ending today, oldest first.
    static func weekDays(_ context: Context) -> [LocalDay] {
        (0..<7).reversed().map { LocalTime.adding(days: -$0, to: context.today) }
    }

    /// Zones for `rows`. Empty until the profile gives both HRmax and last night's resting HR.
    static func zoneMinutes(_ rows: [MinuteMetricRow], context: Context) -> [ZoneMinutes] {
        guard let restingHR = context.restingHR, let maxHR = context.maxHR else { return [] }
        return HeartRateSeries.zoneMinutes(rows, restingHR: restingHR, maxHR: maxHR)
    }

    static func stressSamples(_ rows: [MinuteMetricRow]) -> [(ms: Int64, value: Int)] {
        rows.compactMap { row in row.stress.map { (ms: row.minuteMs, value: $0) } }
    }

    // MARK: Today

    struct TodaySnapshot: Sendable {
        struct Point: Sendable, Identifiable {
            let id: Int64
            let date: Date
            let bpm: Int
        }

        let context: Context
        /// Raw samples for the last 15 minutes.
        let sparkline: [Point]
        /// The newest minute row, if any minute was computed in the last 10 minutes.
        let latestMinute: MinuteMetricRow?
        let today: DaySummary?
        /// Stress for the local day so far, in 15-minute buckets.
        let stressBuckets: [StressBucket]
        /// Stress for the local day so far, averaged and counted by band.
        let stressDay: StressDaySummary
        /// Heart-rate zones for the local day so far.
        let zones: [ZoneMinutes]
        /// Seven local days, oldest first, ending today.
        let week: [DaySummary]

        /// Today's sample-weighted mean heart rate, from `today`.
        var hrAvg: Double? { today?.hrAvg }
        /// Today's highest minute heart rate, from `today`.
        var hrMax: Int? { today?.hrMax }
        /// Fraction of today's 1440 minutes with heart-rate samples, from `today`.
        var coverage: Double { today?.coverage ?? 0 }
        /// Today's mean stress, from `stressDay`.
        var stressAverage: Double? { stressDay.average }
        /// Today's highest minute stress, from `stressDay`.
        var stressPeak: Int? { stressDay.peak }
    }

    static func today(_ db: Database, nowMs: Int64) throws -> TodaySnapshot {
        let context = try Context.load(db, nowMs: nowMs)
        let samples = try db.heartRateRows(from: nowMs - 15 * LocalTime.msPerMinute, to: nowMs)
        let recent = try db.minuteMetricRows(from: nowMs - 10 * LocalTime.msPerMinute, to: nowMs)
        let dayStart = LocalTime.localTime(context.today, hour: 0, in: context.timeZone)
        let dayRows = try db.minuteMetricRows(from: dayStart, to: nowMs)
        let stress = stressSamples(dayRows)
        return TodaySnapshot(
            context: context,
            sparkline: samples.map { TodaySnapshot.Point(id: $0.rowid, date: Date(epochMs: $0.tsMs), bpm: $0.bpm) },
            latestMinute: recent.last,
            today: try db.daySummaries([context.today], in: context.timeZone).first,
            stressBuckets: StressBuckets.make(stress, bucketMs: stressBucketMs),
            stressDay: StressDaySummary.make(samples: stress),
            zones: zoneMinutes(dayRows, context: context),
            week: try db.daySummaries(weekDays(context), in: context.timeZone)
        )
    }

    // MARK: Timelines and calibration

    /// How close the stress baseline is to ready: qualifying days, the 7-day requirement, and the
    /// per-day shortfall. Uses the same rules as scoring, so its counts match `StressBaseline.build`.
    static func stressCalibration(
        _ db: Database,
        nowMs: Int64,
        context: Context? = nil
    ) throws -> StressCalibrationProgress {
        let context = try context ?? Context.load(db, nowMs: nowMs)
        guard let maxHR = context.maxHR else { return .unavailable }
        let day = LocalTime.localDay(containing: nowMs, in: context.timeZone)
        let lookback = try db.stressLookback(for: day, in: context.timeZone)
        return Stress.calibrationProgress(
            windows: lookback.windows,
            day: day,
            nights: lookback.nights,
            restingHR: context.restingHR,
            maxHR: maxHR
        )
    }

    // MARK: Calories

    struct CaloriesSnapshot: Sendable {
        struct Hour: Sendable, Identifiable {
            let id: Int
            let resting: Double
            let active: Double
        }

        let total: Double?
        let active: Double?
        let hours: [Hour]
        /// Seven local days, oldest first, ending today.
        let week: [DaySummary]
        let context: Context
    }

    static func calories(_ db: Database, nowMs: Int64) throws -> CaloriesSnapshot {
        let context = try Context.load(db, nowMs: nowMs)
        let dayStart = LocalTime.localTime(context.today, hour: 0, in: context.timeZone)
        let dayEnd = LocalTime.localTime(LocalTime.adding(days: 1, to: context.today), hour: 0, in: context.timeZone)
        let rows = try db.minuteMetricRows(from: dayStart, to: min(dayEnd, nowMs))
        var resting = Array(repeating: 0.0, count: 24)
        var active = Array(repeating: 0.0, count: 24)
        for row in rows {
            let hour = min(Int((row.minuteMs - dayStart) / (60 * LocalTime.msPerMinute)), 23)
            resting[hour] += row.kcal - row.activeKcal
            active[hour] += row.activeKcal
        }
        let summary = try db.daySummaries([context.today], in: context.timeZone).first
        return CaloriesSnapshot(
            total: summary?.kcalTotal,
            active: summary?.kcalActive,
            hours: (0..<24).map { CaloriesSnapshot.Hour(id: $0, resting: resting[$0], active: active[$0]) },
            week: try db.daySummaries(weekDays(context), in: context.timeZone),
            context: context
        )
    }

    // MARK: Sleep

    /// Derived sleep sessions for the last 7 local nights (PLAN.md 8.1, 10.2 v2). Sessions come from
    /// the band's offloaded history (PLAN.md 5.3.4), so a launch with no offload shows none.
    struct SleepSnapshot: Sendable {
        /// One derived session, reshaped for the UI.
        struct Night: Sendable, Identifiable {
            /// Session start in epoch ms, also the row's identity.
            let id: Int64
            let startMs: Int64
            /// The band the session belongs to; the sleep-edit writes are band-scoped.
            let bandID: String
            /// True when the bed or wake time was corrected by hand (a `sleep_edit` retime).
            let isEdited: Bool
            let durationS: Int64
            /// True for a daytime nap. Naps are listed, but they never stand in for last night.
            let isNap: Bool
            /// Lowest gated 5-minute HR over the session's contact-on records.
            let restingHR: Double?
            let rmssdMs: Double?
            let quality: SleepQuality
            /// Stored hypnogram, ordered and tiled across the session. Empty when this night predates
            /// staging or the session was too short to stage.
            let stages: [StageSegment]
            /// Seconds per stage. Empty when unstaged; all four keys are present when staged.
            let stageTotals: [SleepStage: Int]
            /// Asleep (light + deep + REM) divided by in-bed seconds. Nil when unstaged.
            let efficiency: Double?

            /// True when the store has a hypnogram for this session.
            var isStaged: Bool { !stages.isEmpty }

            /// The headline sleep duration: time asleep (light + deep + REM) when staged, else the
            /// in-bed span. `durationS` is bed → wake, which counts the lying-awake time too.
            var asleepS: Int64 {
                guard isStaged else { return durationS }
                return Int64((stageTotals[.light] ?? 0) + (stageTotals[.deep] ?? 0) + (stageTotals[.rem] ?? 0))
            }
        }

        let context: Context
        /// Sessions overlapping the last 7 local days, newest first.
        let nights: [Night]
        /// Recovery, strain, sleep coaching and regularity for the day the latest main sleep ended
        /// (`Database.dailyScores`). Nil with no main sleep.
        let latestScores: DailyScores?

        /// The most recent main sleep, for Home and Today. Naps are skipped, so a nap taken after a night's
        /// sleep does not replace it.
        var latest: Night? {
            nights.first { !$0.isNap }
        }
    }

    /// Sessions overlapping the last 7 local days for every band in the store, newest first. One band
    /// is the norm; the read is band-scoped because the sleep queries are (PLAN.md 10.2 v2).
    static func sleep(_ db: Database, nowMs: Int64) throws -> SleepSnapshot {
        let context = try Context.load(db, nowMs: nowMs)
        let from = LocalTime.localTime(
            LocalTime.adding(days: -6, to: context.today), hour: 0, in: context.timeZone
        )
        // Keep the band on each row: stage segments are keyed by (band_id, session_start_ms).
        let entries = try BandRow.fetchAll(db).flatMap { band in
            try db.sleepSessionRows(bandID: band.id, from: from, to: nowMs)
                .map { (bandID: band.id, row: $0) }
        }
        let nights = try entries
            .sorted { $0.row.startMs > $1.row.startMs }
            .map { entry -> SleepSnapshot.Night in
                let segments = try db.sleepStageSegments(
                    bandID: entry.bandID,
                    sessionStartMs: entry.row.startMs
                )
                var totals: [SleepStage: Int] = [:]
                if !segments.isEmpty {
                    totals = try db.sleepStageTotals(
                        bandID: entry.bandID,
                        sessionStartMs: entry.row.startMs
                    )
                }
                let stagedSeconds = totals.values.reduce(0, +)
                let asleepSeconds = (totals[.light] ?? 0)
                    + (totals[.deep] ?? 0)
                    + (totals[.rem] ?? 0)
                let efficiency = stagedSeconds > 0
                    ? min(1.0, max(0.0, Double(asleepSeconds) / Double(stagedSeconds)))
                    : nil
                return SleepSnapshot.Night(
                    id: entry.row.startMs,
                    startMs: entry.row.startMs,
                    bandID: entry.bandID,
                    isEdited: try isCorrected(entry.row.startMs, bandID: entry.bandID, in: db),
                    durationS: entry.row.durationS,
                    isNap: entry.row.isNap,
                    restingHR: entry.row.restingHr,
                    rmssdMs: entry.row.rmssdMs,
                    quality: entry.row.qualityValue,
                    stages: segments,
                    stageTotals: totals,
                    efficiency: efficiency
                )
            }
        let latestScores = try nights.first(where: { !$0.isNap }).map { night in
            let wakeDay = LocalTime.localDay(containing: night.startMs + night.durationS * 1000, in: context.timeZone)
            return try db.dailyScores(day: wakeDay, in: context.timeZone)
        }
        return SleepSnapshot(context: context, nights: nights, latestScores: latestScores)
    }

    /// True when the night at `startMs` shows a hand-corrected bed or wake time (a retime keyed by it).
    private static func isCorrected(_ startMs: Int64, bandID: String, in db: Database) throws -> Bool {
        try db.sleepEdits(bandID: bandID).contains { $0.kindValue == .retime && $0.newStartMs == startMs }
    }
}
