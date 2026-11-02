import AlarmKitBridge
import BandKit
import BandProtocol
import Foundation
import GRDB
import Metrics
import Store
import SwiftUI
import SyncKit

/// Owns the store, the clock, the ingestion pipeline and sync. Built once at launch (PLAN.md 7.3, 7.4, 11).
@MainActor
final class AppEnvironment {
    let database: AppDatabase
    let clock: AppClock
    /// True when the store could not open its file and runs in memory for this launch. Nothing is kept.
    let storageFailed: Bool
    let sync: SyncController
    let alarms: AlarmCoordinator

    private let metrics: MetricsWorker
    /// Runs sleep + metric derivation once per settled drain (see `HistoryPipeline`).
    private let derivation: HistoryDerivationScheduler
    private let ingestor: Ingestor
    private let inputs: AsyncStream<Ingestor.Input>
    private let inputContinuation: AsyncStream<Ingestor.Input>.Continuation
    /// Seeded launches show fixed data, so live readings are not written over it.
    private let ingestsLiveData: Bool
    /// Fixture launches make no sync calls and run no sync timer.
    private let isSyncFixture: Bool
    private var ingestionStarted = false
    private var syncStarted = false
    /// The auto-restore reached a verdict this launch (see `autoRestoreIfStoreEmpty`). Set only
    /// after the store check (and, for the empty case, after the attempt), never up front.
    private var didAutoRestore = false
    /// A store check/restore attempt is running; gates duplicate `.ready` observers.
    private var autoRestoreInFlight = false

    private init(
        database: AppDatabase,
        clock: AppClock,
        storageFailed: Bool,
        ingestsLiveData: Bool,
        sync: SyncController,
        isSyncFixture: Bool,
        livesAlarms: Bool
    ) {
        self.database = database
        self.clock = clock
        self.storageFailed = storageFailed
        self.ingestsLiveData = ingestsLiveData
        self.sync = sync
        self.isSyncFixture = isSyncFixture
        // UI tests and seeded launches never touch AlarmKit or the notification centre, so no prompt can appear.
        self.alarms = AlarmCoordinator(
            database: database,
            scheduler: livesAlarms ? AlarmKitScheduler() : InMemoryAlarmScheduler(),
            notifier: livesAlarms ? AlarmNotifier() : nil,
            sync: sync,
            clock: clock
        )
        let metrics = MetricsWorker(database: database)
        self.metrics = metrics
        self.derivation = HistoryDerivationScheduler(database: database, clock: clock)
        self.ingestor = Ingestor(database: database, metrics: metrics, clock: clock, onFlushed: {
            await sync.enqueueBackgroundUploadIfNeeded()
        })
        let (inputs, continuation) = AsyncStream.makeStream(of: Ingestor.Input.self)
        self.inputs = inputs
        self.inputContinuation = continuation
    }

    static func make(_ config: LaunchConfig) -> AppEnvironment {
        let clock = AppClock(fixedNow: config.fixedNow)
        if config.seedDB == "seed_30d", let seeded = try? SeedData.make30Days(now: clock.now) {
            return AppEnvironment(
                database: seeded, clock: clock, storageFailed: false, ingestsLiveData: false,
                sync: makeSync(database: seeded, mode: .memory), isSyncFixture: false, livesAlarms: false
            )
        }
        if config.syncFixture == "paired" {
            let database = inMemory()
            return AppEnvironment(
                database: database, clock: clock, storageFailed: false, ingestsLiveData: false,
                sync: makeSync(database: database, mode: .fixture(now: clock.now)), isSyncFixture: true,
                livesAlarms: false
            )
        }
        if config.isUITest {
            let database = inMemory()
            return AppEnvironment(
                database: database, clock: clock, storageFailed: false, ingestsLiveData: true,
                sync: makeSync(database: database, mode: .memory), isSyncFixture: false, livesAlarms: false
            )
        }
        if let url = storeURL(), let file = try? AppDatabase.file(at: url) {
            #if DEBUG
            // Band log capture (BandLogger): the durable record of handshakes and offload drains.
            if !config.isUITest, let directory = appSupportDirectory() {
                BandLog.startCapture(
                    at: directory
                        .appendingPathComponent("Icarus", isDirectory: true)
                        .appendingPathComponent("band_log.txt")
                )
            }
            // One-time junk cleanup: launch with `-purge-junk-records` to delete the garbage
            // `historical_record` rows an old buggy parser wrote (see `purgeJunkRecords`).
            if ProcessInfo.processInfo.arguments.contains("purge-junk-records") {
                Task { await purgeJunkRecords(in: file, nowMs: clock.nowMs) }
            }
            #endif
            return AppEnvironment(
                database: file, clock: clock, storageFailed: false, ingestsLiveData: true,
                sync: makeSync(database: file, mode: .durable), isSyncFixture: false, livesAlarms: true
            )
        }
        let database = inMemory()
        return AppEnvironment(
            database: database, clock: clock, storageFailed: true, ingestsLiveData: true,
            sync: makeSync(database: database, mode: .memory), isSyncFixture: false, livesAlarms: false
        )
    }

    /// Where readings go, or nil when the launch does not ingest.
    var ingestSink: AsyncStream<Ingestor.Input>.Continuation? {
        ingestsLiveData ? inputContinuation : nil
    }

    /// Rebuilds minute rows marked stale, in the background: rows from an older algorithm version, and the days a
    /// medication or dose edit invalidated (`Database.markStressStale`). Safe to call repeatedly.
    func recomputeStaleMetrics() {
        let metrics = metrics
        let database = database
        let nowMs = clock.nowMs
        Task.detached(priority: .utility) {
            do {
                let result = try await metrics.recomputeStaleRows(nowMs: nowMs)
                // A medication edit changes stress on its days, and the day scores cache holds that stress average.
                if result.ran {
                    try await database.refreshDailyScores(lastDays: MetricsWorker.maxBackfillDays, nowMs: nowMs)
                }
            } catch {
                BandLog.tierB(.error, "app: stale metric recompute failed: \(String(describing: error))")
            }
        }
    }

    /// Fills the `daily_score` cache for the last `DailyScoreCache.backfillDays` days when it is empty or was built by
    /// an older score algorithm. Runs once per launch in the background, one write transaction per day.
    func backfillDailyScoresIfNeeded() {
        let database = database
        let nowMs = clock.nowMs
        Task.detached(priority: .utility) {
            do {
                guard try await database.dailyScoresNeedBackfill() else { return }
                try await database.refreshDailyScores(lastDays: DailyScoreCache.backfillDays, nowMs: nowMs)
                BandLog.tierB(.info, "app: daily scores backfilled for \(DailyScoreCache.backfillDays) days")
            } catch {
                BandLog.tierB(.error, "app: daily score backfill failed: \(String(describing: error))")
            }
        }
    }

    /// Starts the ingest loop and the 5-second flush tick. Safe to call more than once.
    func startIngestion() {
        guard ingestsLiveData, !ingestionStarted else { return }
        ingestionStarted = true
        let ingestor = ingestor
        let inputs = inputs
        // Minute rows from an older algorithm version are rebuilt once per launch (PLAN.md 8.5).
        recomputeStaleMetrics()
        backfillDailyScoresIfNeeded()
        Task { await ingestor.run(inputs) }
        let continuation = inputContinuation
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                continuation.yield(.tick)
            }
        }
    }

    /// Writes pending readings now. Called when the app leaves the foreground (PLAN.md 7.2).
    func flushIngestion() {
        inputContinuation.yield(.flush)
    }

    /// Wires the band's history offload into the store (PLAN.md 5.3.4, 7.3). Like live readings,
    /// records are attributed to the remembered band, else the first band seen. Nothing is wired
    /// when the launch does not ingest.
    ///
    /// A transport that takes a history sink (the real strap) writes each batch through
    /// `HistoryPipeline.persist` BEFORE acking it; its `.historical` event then only schedules
    /// derivation. A transport without one (fixtures) still emits unacked-by-us batches, which are
    /// persisted from the event.
    /// Stores every band event with its payload and the moment's context (charging, heart rate, battery), so
    /// unnamed event ids can be identified from what was happening (Event Log, Band Tests).
    func connectBandEvents(band: LiveState) {
        guard ingestsLiveData else { return }
        let database = database
        band.onBandEventRecord = { [weak band] event in
            guard let band, let bandID = band.rememberedID ?? band.bands.first?.id else { return }
            var context: [String: Any] = [
                "id": Int(event.id),
                "hex": event.payload.map { String(format: "%02x", $0) }.joined(),
            ]
            context["charging"] = band.isCharging
            context["hr"] = band.latestBPM
            context["battery"] = band.batteryPercent
            let payload = (try? JSONSerialization.data(withJSONObject: context, options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) }
            let tsMs = Int64(event.at.timeIntervalSince1970 * 1000)
            let kind = event.kind.storageName
            Task.detached(priority: .utility) {
                do {
                    try await database.writer.write { db in
                        try db.recordBandEvent(peripheralUUID: bandID, tsMs: tsMs, kind: kind, payload: payload)
                    }
                } catch {
                    BandLog.tierB(.error, "app: storing band event \(kind) failed: \(String(describing: error))")
                }
            }
        }
    }

    func connectHistoricalRecords(band: LiveState) {
        guard ingestsLiveData else { return }
        let database = database
        let derivation = derivation
        let sinkInstalled = band.installHistoricalSink { [weak band] records in
            let bandID = await MainActor.run { band?.rememberedID ?? band?.bands.first?.id }
            guard let bandID else {
                BandLog.tierB(.error, "app: no band ID for \(records.count) historical record(s)")
                return false
            }
            return await HistoryPipeline.persist(records, from: bandID, in: database)
        }
        band.onHistoricalRecords = { [weak band] records in
            let times = records.map { Int64($0.unixSeconds) * 1000 }
            guard let fromMs = times.min(), let toMs = times.max() else { return }
            if sinkInstalled {
                Task { await derivation.noteStored(fromMs: fromMs, toMs: toMs) }
                return
            }
            guard let bandID = band?.rememberedID ?? band?.bands.first?.id else {
                BandLog.tierB(.error, "app: no band ID for \(records.count) historical record(s)")
                return
            }
            Task.detached(priority: .utility) {
                if await HistoryPipeline.persist(records, from: bandID, in: database) {
                    await derivation.noteStored(fromMs: fromMs, toMs: toMs)
                }
            }
        }
        band.onTierBChange = { [weak self, weak band] state in
            guard state == .ready else { return }
            guard let self, let band else { return }
            Task { await self.autoRestoreIfStoreEmpty(band: band) }
        }
        // A profile zone that is not the device's, or sessions from an older detection algorithm,
        // are fixed once at launch, off the main actor.
        let clock = clock
        Task.detached(priority: .utility) {
            await HistoryPipeline.syncProfileTimeZone(in: database, nowMs: clock.nowMs)
            await HistoryPipeline.rederiveAllIfStale(in: database, nowMs: clock.nowMs)
            await HistoryPipeline.backfillDayReadingsIfNeeded(in: database)
        }
    }

    /// The app-deleted restore: when the channel first goes ready and the store holds no drained
    /// history at all, rewind the strap's read cursor and re-drain its whole stored history (the
    /// strap's flash is retained across app deletions; OpenStrap §4.3). Once per launch for the
    /// empty-store case; a failed store check is not a verdict, so a later ready may retry it.
    private func autoRestoreIfStoreEmpty(band: LiveState) async {
        guard !didAutoRestore, !autoRestoreInFlight else { return }
        autoRestoreInFlight = true
        defer { autoRestoreInFlight = false }
        do {
            let count = try await database.writer.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM historical_record") ?? 0
            }
            guard count == 0 else {
                didAutoRestore = true
                BandLog.tierB(.info, "app: store has \(count) historical row(s); no auto-restore")
                return
            }
            BandLog.tierB(.info, "app: store is empty — auto-restoring the strap's full stored history")
            // `drainFullHistory` waits out the connect drain if it is already running, so the
            // restore is not denied as "0 drains" by the race.
            await band.drainFullHistory()
            didAutoRestore = true
        } catch {
            // Leave `didAutoRestore` false: this was not a genuine attempt, and a later ready
            // (reconnect) should be allowed to retry.
            BandLog.tierB(.error, "app: auto-restore check failed: \(String(describing: error))")
        }
    }

    #if DEBUG
    /// A consistent snapshot of the just-drained window plus the latest sessions, written as one
    /// JSON file. File copies of a live WAL database race with checkpoints, so a computer pulls
    /// this instead of `icarus.sqlite` to see what the app really stored.
    nonisolated static func writeDebugDump(from fromMs: Int64, to toMs: Int64, in database: AppDatabase) async {
        struct Dump: Codable, Sendable {
            let fromMs: Int64
            let toMs: Int64
            let records: [HistoricalRecordRow]
            let sessions: [SleepSessionRow]
        }
        guard let url = debugDumpURL() else { return }
        let dump: Dump? = try? await database.writer.read { db in
            Dump(
                fromMs: fromMs,
                toMs: toMs,
                records: try HistoricalRecordRow.fetchAll(db, sql: """
                SELECT * FROM historical_record WHERE ts_ms >= ? AND ts_ms <= ? ORDER BY ts_ms
                """, arguments: [fromMs, toMs]),
                sessions: try SleepSessionRow.fetchAll(db, sql: """
                SELECT * FROM sleep_session ORDER BY start_ms DESC LIMIT 50
                """)
            )
        }
        if let dump, let data = try? JSONEncoder().encode(dump) {
            try? data.write(to: url, options: .atomic)
        }
    }
    #endif

    /// Sync on launch, then on the foreground timer at the chosen interval (PLAN.md 11.2).
    func startSync() {
        guard !syncStarted, !isSyncFixture else { return }
        syncStarted = true
        let sync = sync
        Task { await sync.runNow() }
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Int(SyncInterval.stored().seconds)))
                await sync.runNow()
            }
        }
    }

    /// Scene phase changes: flush readings when leaving the foreground, schedule background work when entering the
    /// background, and sync when becoming active.
    func scenePhaseChanged(_ phase: ScenePhase) {
        sync.isForeground = phase == .active
        if phase != .active {
            flushIngestion()
        }
        if phase == .background, !isSyncFixture {
            BackgroundTasks.scheduleRefresh()
            BackgroundTasks.scheduleMaintenance()
        }
        if phase == .active, syncStarted {
            Task { await sync.runNow() }
        }
        if phase == .active {
            Task { await alarms.rearmAll() }
        }
    }

    /// The BGAppRefreshTask body (PLAN.md 11.2).
    func runBackgroundRefresh() async {
        await sync.runNow()
    }

    /// The BGProcessingTask body: backlog sync, then the retention purge (PLAN.md 10.2, 11.2).
    func runMaintenance() async {
        await sync.runNow()
        let nowMs = clock.nowMs
        try? await database.writer.write { db in
            try db.purgeExpired(nowMs: nowMs)
        }
    }

    /// Reads a snapshot now and every `interval` while the consumer keeps iterating. Detail screens use this
    /// instead of observation: their queries span hours or days, and re-running them on every flush is wasteful.
    func snapshots<T: Sendable>(
        every interval: Duration,
        _ load: @escaping @Sendable (Database, Int64) throws -> T
    ) -> AsyncStream<T> {
        let database = database
        let clock = clock
        return AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    if let value = try? await database.writer.read({ try load($0, clock.nowMs) }) {
                        continuation.yield(value)
                    }
                    do {
                        try await Task.sleep(for: interval)
                    } catch {
                        break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Store file in Application Support. Protection is set by `AppDatabase.file` (PLAN.md 7.4).
    private static func storeURL() -> URL? {
        appSupportDirectory()?
            .appendingPathComponent("Icarus", isDirectory: true)
            .appendingPathComponent("icarus.sqlite")
    }

    private static func appSupportDirectory() -> URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    #if DEBUG
    /// Nonisolated, for debug write paths that run off the main actor.
    private nonisolated static func debugDumpURL() -> URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Icarus", isDirectory: true)
            .appendingPathComponent("debug_dump.json")
    }

    /// Records older than this ts_ms (2026-01-01) predate anything the band can produce. The garbage
    /// rows were written in 2010–2014 by an old buggy parser. Records a wrong strap clock dated before
    /// the band could have banked them are handled by `BandHistoryReach` (schema v12 and ingest).
    private nonisolated static let junkRecordCutoffMs: Int64 = 1_767_225_600_000

    /// One-time cleanup of the 8 garbage `historical_record` rows from the old buggy parser, and
    /// of the `sleep_session` spam the sliding per-batch derivation window wrote (each flush
    /// re-derived a ~30-min clipped session with a new start key): launched with
    /// `-purge-junk-records`, it deletes every historical row with ts_ms before 2026-01-01, all
    /// sleep_session rows, and logs the counts. Without the launch argument it does nothing. The
    /// next stored batch re-derives the sessions over the full span.
    private static func purgeJunkRecords(in database: AppDatabase, nowMs: Int64) async {
        do {
            let counts = try await database.writer.write { db -> (junk: Int, sessions: Int, rederived: Int) in
                try db.execute(
                    sql: "DELETE FROM historical_record WHERE ts_ms < ?",
                    arguments: [junkRecordCutoffMs]
                )
                let junk = db.changesCount
                try db.execute(sql: "DELETE FROM sleep_stage_segment")
                try db.execute(sql: "DELETE FROM night_reading")
                try db.execute(sql: "DELETE FROM sleep_session")
                let sessions = db.changesCount
                // Re-derive over each band's whole stored span right away, so correct sessions
                // replace what was deleted instead of waiting for the next drain.
                var rederived = 0
                let zone = try db.profile()?.timeZone ?? Dashboard.fallbackZone
                let bands = try String.fetchAll(db, sql: "SELECT id FROM band")
                for bandID in bands {
                    guard
                        let spanMin = try Int64.fetchOne(
                            db, sql: "SELECT MIN(ts_ms) FROM historical_record WHERE band_id = ?",
                            arguments: [bandID]
                        ),
                        let spanMax = try Int64.fetchOne(
                            db, sql: "SELECT MAX(ts_ms) FROM historical_record WHERE band_id = ?",
                            arguments: [bandID]
                        )
                    else { continue }
                    rederived += try db.deriveSleepSessions(
                        from: spanMin,
                        to: spanMax + 1,
                        bandID: bandID,
                        in: zone,
                        computedAtMs: nowMs
                    )
                    _ = try db.deriveSleepStageSegments(
                        from: spanMin,
                        to: spanMax + 1,
                        bandID: bandID,
                        computedAtMs: nowMs
                    )
                }
                return (junk, sessions, rederived)
            }
            BandLog.tierB(.info, "purge-junk-records: deleted \(counts.junk) junk record(s), \(counts.sessions) sleep_session row(s); re-derived \(counts.rederived) session(s)")
        } catch {
            BandLog.tierB(.error, "purge-junk-records failed: \(String(describing: error))")
        }
    }
    #endif

    private enum SyncMode {
        /// Keychain token, files in Application Support, the real network.
        case durable
        /// Nothing persists and nothing leaves the device. Used for UI tests and when the store is in memory.
        case memory
        /// The paired fixture from SyncFixture, seeded at `now`.
        case fixture(now: Date)
    }

    private static func makeSync(database: AppDatabase, mode: SyncMode) -> SyncController {
        switch mode {
        case .durable:
            guard let directory = appSupportDirectory()?
                .appendingPathComponent("Icarus", isDirectory: true)
                .appendingPathComponent("Sync", isDirectory: true)
            else {
                return makeSync(database: database, mode: .memory)
            }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: directory.path
            )
            let outbox = Outbox(directory: directory)
            let engine = SyncEngine(
                database: database,
                outbox: outbox,
                tokens: KeychainTokenStore(),
                transport: URLSessionTransport()
            )
            return SyncController(engine: engine, uploader: BackgroundUploader(outbox: outbox))
        case .memory:
            let engine = SyncEngine(
                database: database,
                outbox: Outbox(directory: temporaryDirectory()),
                tokens: InMemoryTokenStore(),
                transport: OfflineTransport()
            )
            return SyncController(engine: engine, uploader: nil)
        case let .fixture(now):
            let outbox = Outbox(directory: temporaryDirectory())
            let tokens = InMemoryTokenStore()
            let engine = (try? SyncFixture.seedPaired(database: database, outbox: outbox, tokens: tokens, now: now))
                ?? SyncEngine(database: database, outbox: outbox, tokens: tokens, transport: OfflineTransport())
            return SyncController(engine: engine, uploader: nil)
        }
    }

    private static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("icarus-\(UUID().uuidString)", isDirectory: true)
    }

    private static func inMemory() -> AppDatabase {
        guard let database = try? AppDatabase.inMemory() else {
            preconditionFailure("An in-memory store always opens")
        }
        return database
    }
}
