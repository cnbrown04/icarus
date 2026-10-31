import Foundation
import GRDB
import Metrics

/// Recomputes `minute_metric` for closed minutes after each ingest flush (PLAN.md 7.3, 8.1-8.4).
///
/// Each run rewrites the last `lookback` closed minutes. A 5-minute HRV window is final once it has closed
/// and aged out of the lookback. The first run after launch uses a longer lookback to pick up data that
/// arrived before the app was last closed.
///
/// The worker lives in Store, not in the app target, so the recompute can be tested on Linux.
public actor MetricsWorker {
    public static let lookbackMinutes: Int64 = 10
    public static let launchLookbackMinutes: Int64 = 30
    /// The baseline is rebuilt at most this often, or when the local day changes.
    public static let baselineMaxAgeMs: Int64 = 5 * LocalTime.msPerMinute
    /// The most local days one backfill recomputes. Keeps a corrupt or absurd timestamp range
    /// from turning into an unbounded loop of minute rows.
    public static let maxBackfillDays = 60

    /// Result of one run.
    public struct Result: Sendable, Equatable {
        /// Minute rows whose values changed.
        public let changedRows: Int
        /// False when no complete profile exists, so nothing was computed.
        public let ran: Bool
    }

    private struct BaselineCache: Sendable {
        let day: LocalDay
        let computedAtMs: Int64
        let value: StressBaseline
    }

    private let database: AppDatabase
    private var hasRunOnce = false
    private var baseline: BaselineCache?

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Recomputes the closed minutes that fall in the lookback before `nowMs`.
    public func recompute(nowMs: Int64) async throws -> Result {
        let lookback = hasRunOnce ? Self.lookbackMinutes : Self.launchLookbackMinutes
        let cache = baseline
        let (result, newCache) = try await database.writer.write { db -> (Result, BaselineCache?) in
            try Self.run(db, nowMs: nowMs, lookbackMinutes: lookback, cache: cache)
        }
        // A run without a profile computed nothing, so the launch backfill is still owed.
        if result.ran {
            hasRunOnce = true
        }
        if let newCache {
            baseline = newCache
        }
        return result
    }

    /// Recomputes every closed minute of the last `days` local days, oldest day first, one day per
    /// chunk so each chunk's stress baseline is built from the rows already recomputed for the days
    /// before it. Used by the Debug screen's force recompute; the regular ingest path keeps using
    /// `recompute(nowMs:)` with its short lookback. Sleep sessions and daily rollups are separate:
    /// rollups are read-time (`DailyRollup`), sleep is `deriveSleepSessions`.
    public func recomputeBackfill(days: Int, nowMs: Int64) async throws -> Result {
        let clamped = max(1, min(days, Self.maxBackfillDays))
        let cache = baseline
        let (result, newBaseline) = try await database.writer.write { db -> (Result, BaselineCache?) in
            guard let profileRow = try db.profile() else {
                return (Result(changedRows: 0, ran: false), nil)
            }
            let zone = profileRow.timeZone
            let closedThrough = LocalTime.roundDown(nowMs, to: LocalTime.msPerMinute)
            let today = LocalTime.localDay(containing: closedThrough, in: zone)
            var total = 0
            var ran = false
            var cache = cache
            for offset in stride(from: clamped - 1, through: 0, by: -1) {
                let day = LocalTime.adding(days: -offset, to: today)
                let dayStart = LocalTime.localTime(day, hour: 0, in: zone)
                // A ms inside the chunk, so `run` rounds to the day's own minutes and keeps the
                // baseline keyed to `day` rather than to the next midnight.
                let chunkNow = min(closedThrough, LocalTime.localTime(LocalTime.adding(days: 1, to: day), hour: 0, in: zone) - 1)
                let chunkClosed = LocalTime.roundDown(chunkNow, to: LocalTime.msPerMinute)
                // One minute more than the chunk spans, so the last minute of the day (just before
                // the next midnight, outside this chunk's closed minutes) lands in the next chunk.
                let lookback = (chunkClosed - dayStart) / LocalTime.msPerMinute + 1
                guard lookback > 0 else { continue }
                let (chunk, newCache) = try Self.run(db, nowMs: chunkNow, lookbackMinutes: lookback, cache: cache)
                total += chunk.changedRows
                ran = ran || chunk.ran
                if let newCache {
                    cache = newCache
                }
            }
            return (Result(changedRows: total, ran: ran), cache)
        }
        if result.ran {
            hasRunOnce = true
        }
        if let newBaseline {
            baseline = newBaseline
        }
        return result
    }

    /// Recomputes every closed minute touched by the sample range `[fromMs, toMs]`, oldest local
    /// day first. This is the historical-drain follow-up: a drained batch can span hours, so the
    /// regular `recompute(nowMs:)` lookback (10–30 min) would leave every earlier minute without
    /// a `minute_metric` row. Each local-day chunk is run separately so its stress baseline is
    /// built from the days before it, exactly like the whole-day `recomputeBackfill(days:nowMs:)`.
    ///
    /// Minutes that have not closed at `nowMs` are skipped; the regular ingest path recomputes
    /// them once they close. A range wider than `maxBackfillDays` local days is clamped to the
    /// days ending at its newest sample (so even an old drained window is covered), and the
    /// writes are idempotent (`upsertMinuteMetrics`), so replaying a drain batch is harmless.
    public func recomputeBackfill(fromMs: Int64, toMs: Int64, nowMs: Int64) async throws -> Result {
        let closedThrough = LocalTime.roundDown(nowMs, to: LocalTime.msPerMinute)
        let lower = LocalTime.roundDown(min(fromMs, toMs), to: LocalTime.msPerMinute)
        // Include the minute containing the newest sample, provided that minute has closed.
        let upper = min(
            LocalTime.roundDown(max(fromMs, toMs), to: LocalTime.msPerMinute) + LocalTime.msPerMinute,
            closedThrough
        )
        guard upper > lower else { return Result(changedRows: 0, ran: false) }
        let cache = baseline
        let (result, newBaseline) = try await database.writer.write { db -> (Result, BaselineCache?) in
            guard let profileRow = try db.profile() else {
                return (Result(changedRows: 0, ran: false), nil)
            }
            let zone = profileRow.timeZone
            // Clamp a corrupt or absurdly wide range to at most `maxBackfillDays` local days,
            // keeping the days that END at the newest sample: an old drained window is still
            // fully covered, while a garbage 1970…2100 span cannot loop forever.
            let endDay = LocalTime.localDay(containing: upper - 1, in: zone)
            let oldestDay = LocalTime.adding(days: -(Self.maxBackfillDays - 1), to: endDay)
            var cursor = max(lower, LocalTime.localTime(oldestDay, hour: 0, in: zone))
            var total = 0
            var ran = false
            var cache = cache
            while cursor < upper {
                let day = LocalTime.localDay(containing: cursor, in: zone)
                let nextDayStart = LocalTime.localTime(LocalTime.adding(days: 1, to: day), hour: 0, in: zone)
                let chunkEnd = min(upper, nextDayStart)
                let lookback = (chunkEnd - cursor) / LocalTime.msPerMinute
                guard lookback > 0 else { break }
                // `run` rounds `nowMs` down to a minute, so a minute-aligned `chunkEnd` makes the
                // chunk exactly `[cursor, chunkEnd)`. Day attribution comes from `chunkEnd`'s day;
                // a chunk ending at midnight is the previous day's tail, which is all its rows.
                let (chunk, newCache) = try Self.run(db, nowMs: chunkEnd, lookbackMinutes: lookback, cache: cache)
                total += chunk.changedRows
                ran = ran || chunk.ran
                if let newCache {
                    cache = newCache
                }
                cursor = chunkEnd
            }
            return (Result(changedRows: total, ran: ran), cache)
        }
        if result.ran {
            hasRunOnce = true
        }
        if let newBaseline {
            baseline = newBaseline
        }
        return result
    }

    /// Recomputes the minute rows an older algorithm wrote (`AlgoVersion.storedValue`, PLAN.md 8.5), from the
    /// oldest such row to now. The app calls it once at launch, so a stress change reaches the stored history.
    /// Only rows inside the backfill window are checked, so a stale row older than `maxBackfillDays` is left
    /// alone instead of being rebuilt on every launch. Medication edits mark their days stale with
    /// `Database.markStressStale`, and this call picks them up. The baseline cache is dropped first, because a
    /// medication change alters the medicated and unmedicated baselines.
    public func recomputeStaleRows(nowMs: Int64) async throws -> Result {
        baseline = nil
        let current = AlgoVersion.current.storedValue
        let windowStart = nowMs - Int64(Self.maxBackfillDays) * 24 * 60 * LocalTime.msPerMinute
        let oldestStale = try await database.writer.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT MIN(minute_ms) FROM minute_metric WHERE algo_version < ? AND minute_ms >= ?",
                arguments: [current, windowStart]
            )
        }
        guard let oldestStale else { return Result(changedRows: 0, ran: false) }
        return try await recomputeBackfill(fromMs: oldestStale, toMs: nowMs, nowMs: nowMs)
    }

    private static func run(
        _ db: Database,
        nowMs: Int64,
        lookbackMinutes: Int64,
        cache: BaselineCache?
    ) throws -> (Result, BaselineCache?) {
        let notRun = Result(changedRows: 0, ran: false)
        guard let profileRow = try db.profile() else { return (notRun, nil) }
        let timeZone = profileRow.timeZone
        let closedThrough = LocalTime.roundDown(nowMs, to: LocalTime.msPerMinute)
        let start = closedThrough - lookbackMinutes * LocalTime.msPerMinute
        let day = LocalTime.localDay(containing: closedThrough, in: timeZone)
        guard let profile = profileRow.userProfile(year: day.year) else { return (notRun, nil) }
        let maxHR = HeartRateZones.maxHR(userEntered: profileRow.hrMax, ageYears: profile.ageYears)
        let restingHR = try db.restingHeartRate(
            night: NightWindow.latestCompleted(nowMs: closedThrough, in: timeZone),
            in: timeZone
        )

        // Stimulant windows cover the lookback and the scored day. The baseline splits on them, and a window
        // on the scored day is scored against the medicated or unmedicated baseline by its own start.
        let lookbackFirst = LocalTime.adding(days: -Stress.lookbackDays, to: day)
        let stimulantWindows = try db.medicationWindows(from: lookbackFirst, to: day, in: timeZone)
            .filter { $0.medClass == .stimulant }

        var newCache: BaselineCache?
        let stressBaseline: StressBaseline
        if let cache, cache.day == day, closedThrough - cache.computedAtMs < baselineMaxAgeMs {
            stressBaseline = cache.value
        } else {
            let lookback = try db.stressLookback(for: day, in: timeZone)
            stressBaseline = StressBaseline.build(
                windows: lookback.windows,
                day: day,
                nights: lookback.nights,
                restingHR: restingHR,
                maxHR: maxHR,
                stimulantWindows: stimulantWindows
            )
            newCache = BaselineCache(day: day, computedAtMs: closedThrough, value: stressBaseline)
        }

        // Read whole 5-minute windows so HRV is computed over the same beats as a full recompute.
        let readFrom = LocalTime.roundDown(start, to: LocalTime.msPerWindow)
        let readTo = LocalTime.roundUp(closedThrough, to: LocalTime.msPerWindow)
        let samples = try db.heartRateRows(from: readFrom, to: readTo).map { row in
            HeartRateSample(tsMs: row.tsMs, bpm: row.bpm, contact: row.contact.map { $0 ? .detected : .notDetected })
        }
        let rr = try db.acceptedRRRows(from: readFrom, to: readTo).map { RRSample(tsMs: $0.tsMs, rrMs: $0.rrMs) }
        let context = MinuteMetricsContext(
            profile: profile,
            restingHR: restingHR,
            maxHR: maxHR,
            baseline: stressBaseline,
            stimulantWindows: stimulantWindows
        )
        let metrics = MinuteMetricsCalculator.rows(
            range: start..<closedThrough,
            samples: samples,
            rr: rr,
            context: context
        )
        let changed = try db.upsertMinuteMetrics(metrics, computedAtMs: nowMs)
        return (Result(changedRows: changed, ran: true), newCache)
    }
}

/// The night windows in local time (PLAN.md 8.1).
public enum NightWindow {
    /// The most recent night that has finished at `nowMs`, as its local date.
    public static func latestCompleted(nowMs: Int64, in timeZone: TimeZone) -> LocalDay {
        let today = LocalTime.localDay(containing: nowMs, in: timeZone)
        let morningEnd = LocalTime.localTime(today, hour: LocalTime.nightEndHour, in: timeZone)
        return nowMs >= morningEnd ? today : LocalTime.adding(days: -1, to: today)
    }
}

extension FiveMinuteWindow {
    /// Rebuilds 5-minute windows from stored minute rows. Each minute carries its window's RMSSD (PLAN.md
    /// 10.2 has no window table), so the window is the group of minutes that share a 5-minute start.
    public static func rebuilt(from rows: [MinuteMetricRow]) -> [FiveMinuteWindow] {
        var groups: [Int64: [MinuteMetricRow]] = [:]
        for row in rows {
            groups[LocalTime.roundDown(row.minuteMs, to: LocalTime.msPerWindow), default: []].append(row)
        }
        return groups.keys.sorted().map { start in
            let members = groups[start]!
            let withHR = members.filter { $0.hrAvg != nil }
            let count = withHR.reduce(0) { $0 + $1.hrN }
            let hrMean: Double? = count > 0
                ? withHR.reduce(0.0) { $0 + ($1.hrAvg ?? 0) * Double($1.hrN) } / Double(count)
                : nil
            let rmssd = members.compactMap(\.rmssdMs).first
            return FiveMinuteWindow(
                startMs: start,
                hrMean: hrMean,
                rrCount: 0,
                rrSumMs: 0,
                valid: rmssd != nil,
                rmssd: rmssd,
                sdnn: members.compactMap(\.sdnnMs).first,
                lnRmssd: rmssd.map { log($0) },
                baevskySqrt: members.compactMap(\.baevskySqrt).first
            )
        }
    }
}
