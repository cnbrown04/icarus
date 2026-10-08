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

        var newCache: BaselineCache?
        let stressBaseline: StressBaseline
        if let cache, cache.day == day, closedThrough - cache.computedAtMs < baselineMaxAgeMs {
            stressBaseline = cache.value
        } else {
            let lookbackStart = LocalTime.localTime(
                LocalTime.adding(days: -Stress.lookbackDays, to: day),
                hour: 0,
                in: timeZone
            )
            let dayStart = LocalTime.localTime(day, hour: 0, in: timeZone)
            let stored = try db.minuteMetricRows(from: lookbackStart, to: dayStart)
            stressBaseline = StressBaseline.build(
                windows: FiveMinuteWindow.rebuilt(from: stored),
                day: day,
                in: timeZone,
                restingHR: restingHR,
                maxHR: maxHR
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
            baseline: stressBaseline
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
