import BandKit
import BandProtocol
import Foundation
import GRDB
import Metrics
import Store
import UIKit

/// Drained strap history → store → derived sleep and minute metrics (PLAN.md 5.3.4, 8.1).
///
/// Two halves, deliberately split:
/// - `persist` is the per-batch path. It runs while the strap waits for the batch's ack, so it only
///   inserts rows (history, plus the hr_sample/rr_interval backfill the HR graph reads) and returns.
/// - `derive` is the per-drain path: sleep detection + staging and the minute-metric backfill over
///   the drained range, coalesced by `HistoryDerivationScheduler` so it runs once after a drain
///   settles instead of once per 50-record batch. Per-batch derivation over the whole stored span
///   took ~4 s a batch against batches every ~0.4 s; the backlog queued in memory behind an
///   already-sent ack and was lost whenever iOS suspended the app, which kept only ~3 of every 16
///   minutes of history.
enum HistoryPipeline {
    /// Sleep is re-derived for sessions starting this far before the drained range, so a night the
    /// new records extend (it may have started up to `SleepDetector.maxSleepSeconds` earlier) and
    /// its same-day competitors for "main sleep" are all re-decided.
    static let rederiveLookbackMs: Int64 = 24 * 60 * 60 * 1000

    /// Inserts one batch. True when the rows are durably written (or were already there), which is
    /// what lets the strap's ack go out.
    static func persist(
        _ records: [BandProtocol.HistoricalRecord],
        from bandUUID: UUID,
        in database: AppDatabase
    ) async -> Bool {
        guard !records.isEmpty else { return true }
        let samples = records.map { sample($0, from: bandUUID) }
        do {
            try await database.writer.write { db in
                try db.insertHistoricalSamples(samples)
                // Backfill the realtime tables from the drained history: the HR graph reads
                // hr_sample, which only the realtime ingest writes, so a drained gap (app closed,
                // strap kept banking) would otherwise stay invisible there forever. Same
                // physiological gate as ReadingPreparer (PLAN.md 7.3); INSERT OR IGNORE dedupes
                // against realtime samples and replayed drain batches.
                let readings = samples.compactMap { sample -> Database.Reading? in
                    guard let bpm = sample.bpm, (20...250).contains(bpm) else { return nil }
                    return Database.Reading(
                        peripheralUUID: bandUUID,
                        tsMs: sample.tsMs,
                        bpm: bpm,
                        contact: sample.contact,
                        rr: sample.rrMs.enumerated().map { index, ms in
                            .init(seq: index, rrMs: ms, accepted: true)
                        }
                    )
                }
                if !readings.isEmpty {
                    try db.insertReadings(readings)
                }
            }
            return true
        } catch {
            BandLog.tierB(.error, "app: storing \(records.count) historical record(s) failed: \(String(describing: error))")
            return false
        }
    }

    /// Re-derives sleep and minute metrics for drained records spanning `[fromMs, toMs]`.
    static func derive(fromMs: Int64, toMs: Int64, in database: AppDatabase, nowMs: Int64) async {
        do {
            let staged = try await database.writer.write { db -> Int in
                let zone = try db.profile()?.timeZone ?? Dashboard.fallbackZone
                var staged = 0
                for bandID in try String.fetchAll(db, sql: "SELECT id FROM band") {
                    try db.deriveSleepSessions(
                        from: fromMs - rederiveLookbackMs,
                        to: toMs + 1,
                        bandID: bandID,
                        in: zone,
                        computedAtMs: nowMs
                    )
                    staged += try db.deriveSleepStageSegments(
                        from: fromMs - rederiveLookbackMs,
                        to: toMs + 1,
                        bandID: bandID,
                        computedAtMs: nowMs
                    )
                }
                return staged
            }
            BandLog.tierB(.info, "app: sleep derived for \(fromMs)…\(toMs) (\(staged) stage segment(s) written)")
            // Minute metrics for the WHOLE drained range, not a short tail: a night's backlog spans
            // hours, and the worker chunks by local day, oldest first, so each stress baseline sees
            // the already-recomputed days.
            _ = try await MetricsWorker(database: database)
                .recomputeBackfill(fromMs: fromMs, toMs: toMs, nowMs: nowMs)
            // Activities read the minute rows that were just recomputed, so they run last. Same lookback as
            // sleep: a bout that began before the drained range is re-detected whole.
            try await database.writer.write { db in
                let zone = try db.profile()?.timeZone ?? Dashboard.fallbackZone
                try db.detectActivities(
                    from: fromMs - rederiveLookbackMs,
                    to: toMs + 1,
                    in: zone,
                    computedAtMs: nowMs
                )
            }
            // Day scores from the drained days (plus the lookback, since a night can begin the evening before)
            // THROUGH TODAY: recovery and sleep debt read baselines over the preceding days, so a drain of older
            // history changes later days' scores too. One write transaction per day; a normal drain covers ~1–2 days.
            try await database.refreshDailyScores(fromMs: fromMs - rederiveLookbackMs, toMs: max(toMs, nowMs), nowMs: nowMs)
            #if DEBUG
            await AppEnvironment.writeDebugDump(from: fromMs, to: toMs, in: database)
            #endif
        } catch {
            BandLog.tierB(.error, "app: deriving history \(fromMs)…\(toMs) failed: \(String(describing: error))")
        }
    }

    /// Re-derives every band's whole stored span when the stored sessions came from an older
    /// `SleepDeriver.algoVersion` (or none exist yet). Version 1 sessions were whole worn days, not
    /// sleep, so they are deleted outright rather than left for the range rule to find.
    static func rederiveAllIfStale(in database: AppDatabase, nowMs: Int64) async {
        do {
            let span = try await database.writer.write { db -> (Int64, Int64)? in
                let stale = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM sleep_session WHERE algo_version < ?",
                    arguments: [SleepDeriver.algoVersion]
                ) ?? 0
                let sessions = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sleep_session") ?? 0
                guard stale > 0 || sessions == 0,
                      let lo = try Int64.fetchOne(db, sql: "SELECT MIN(ts_ms) FROM historical_record"),
                      let hi = try Int64.fetchOne(db, sql: "SELECT MAX(ts_ms) FROM historical_record")
                else { return nil }
                try db.execute(sql: "DELETE FROM sleep_stage_segment")
                try db.execute(sql: "DELETE FROM sleep_session")
                BandLog.tierB(.info, "app: \(stale) sleep session(s) from an older algorithm; re-deriving all history")
                return (lo, hi)
            }
            guard let (lo, hi) = span else { return }
            await derive(fromMs: lo + rederiveLookbackMs, toMs: hi, in: database, nowMs: nowMs)
        } catch {
            BandLog.tierB(.error, "app: sleep re-derive check failed: \(String(describing: error))")
        }
    }

    /// Keeps the profile's zone on the device's. Profiles used to be saved with a hard-coded
    /// "America/Chicago", so on a phone in Eastern time every local time — sleep bounds, the
    /// daytime-nap guard, day boundaries — was an hour off. A change drops the stored sleep sessions
    /// (their local-time decisions are stale) so `rederiveAllIfStale` rebuilds them.
    static func syncProfileTimeZone(in database: AppDatabase, nowMs: Int64) async {
        let device = TimeZone.current.identifier
        do {
            try await database.writer.write { db in
                guard var profile = try db.profile(), profile.tz != device else { return }
                BandLog.tierB(.info, "app: profile time zone \(profile.tz) → \(device) (device)")
                profile.tz = device
                try db.saveProfile(profile, atMs: nowMs)
                try db.execute(sql: "DELETE FROM sleep_stage_segment")
                try db.execute(sql: "DELETE FROM sleep_session")
            }
        } catch {
            BandLog.tierB(.error, "app: profile time zone sync failed: \(String(describing: error))")
        }
    }

    private static func sample(_ record: BandProtocol.HistoricalRecord, from bandUUID: UUID) -> Database.HistoricalSample {
        Database.HistoricalSample(
            peripheralUUID: bandUUID,
            tsMs: Int64(record.unixSeconds) * 1000,
            version: Int(record.version),
            bpm: record.heartRate == 0 ? nil : record.heartRate,
            contact: record.skinContact,
            rrMs: record.rrIntervalsMs.map(Double.init),
            ppgGreen: raw(record.ppgGreen),
            ppgRedIr: raw(record.ppgRedIr),
            spo2Red: raw(record.spo2Red),
            spo2Ir: raw(record.spo2Ir),
            skinTempRaw: raw(record.skinTempRaw),
            respRateRaw: raw(record.respRateRaw),
            signalQuality: raw(record.signalQuality),
            gravityX: record.gravity.x,
            gravityY: record.gravity.y,
            gravityZ: record.gravity.z,
            gravity2X: record.secondaryGravity.x,
            gravity2Y: record.secondaryGravity.y,
            gravity2Z: record.secondaryGravity.z,
            ambientDrive: raw(record.ambientDrive),
            ledDrive1: raw(record.ledDrive1),
            ledDrive2: raw(record.ledDrive2)
        )
    }

    /// A sensor raw byte for the store: 0 means the strap recorded nothing (PLAN.md 10.2 v2).
    private static func raw(_ value: UInt16) -> Int? {
        value == 0 ? nil : Int(value)
    }
}

/// Coalesces stored batches into one derivation per drain: each batch widens the pending range and
/// pushes the run back by `quietSeconds`, so a 60-second drain derives once, a few seconds after its
/// last batch. The run holds a UIKit background assertion so suspension does not cut it short.
actor HistoryDerivationScheduler {
    /// Batches arrive every ~0.4 s during a drain; this much silence means the drain has settled.
    static let quietSeconds = 4.0

    private let database: AppDatabase
    private let clock: AppClock
    private var pending: (from: Int64, to: Int64)?
    private var timer: Task<Void, Never>?
    private var running = false

    init(database: AppDatabase, clock: AppClock) {
        self.database = database
        self.clock = clock
    }

    /// Records that rows spanning `[fromMs, toMs]` were stored, and (re)arms the quiet timer.
    func noteStored(fromMs: Int64, toMs: Int64) {
        if let current = pending {
            pending = (min(current.from, fromMs), max(current.to, toMs))
        } else {
            pending = (fromMs, toMs)
        }
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.quietSeconds))
            guard !Task.isCancelled else { return }
            await self?.runPending()
        }
    }

    private func runPending() {
        // One derivation at a time; batches stored meanwhile re-arm the timer and run next. The
        // derivation runs in its own task: the timer task is cancelled whenever a batch lands, and
        // a derivation running inside it died with CancellationError and lost its range.
        guard !running, let range = pending else { return }
        pending = nil
        running = true
        let database = database
        let nowMs = clock.nowMs
        Task.detached(priority: .utility) { [weak self] in
            let task = await MainActor.run {
                UIApplication.shared.beginBackgroundTask(withName: "icarus.history.derive")
            }
            await HistoryPipeline.derive(fromMs: range.from, toMs: range.to, in: database, nowMs: nowMs)
            await MainActor.run {
                UIApplication.shared.endBackgroundTask(task)
            }
            await self?.finished()
        }
    }

    private func finished() {
        running = false
        if let next = pending {
            noteStored(fromMs: next.from, toMs: next.to)
        }
    }
}
