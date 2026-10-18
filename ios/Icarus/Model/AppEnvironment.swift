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
    private let ingestor: Ingestor
    private let inputs: AsyncStream<Ingestor.Input>
    private let inputContinuation: AsyncStream<Ingestor.Input>.Continuation
    /// Seeded launches show fixed data, so live readings are not written over it.
    private let ingestsLiveData: Bool
    /// Fixture launches make no sync calls and run no sync timer.
    private let isSyncFixture: Bool
    private var ingestionStarted = false
    private var syncStarted = false

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

    /// Starts the ingest loop and the 5-second flush tick. Safe to call more than once.
    func startIngestion() {
        guard ingestsLiveData, !ingestionStarted else { return }
        ingestionStarted = true
        let ingestor = ingestor
        let inputs = inputs
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

    /// Wires the band's history offload into the store (PLAN.md 5.3.4, 7.3). Records flow out of
    /// LiveState through `onHistoricalRecords`; like live readings, they are attributed to the
    /// remembered band, else the first band seen. Nothing is wired when the launch does not ingest.
    func connectHistoricalRecords(band: LiveState) {
        guard ingestsLiveData else { return }
        band.onHistoricalRecords = { [weak self, weak band] records in
            guard let bandID = band?.rememberedID ?? band?.bands.first?.id else {
                BandLog.tierB(.error, "app: no band ID for \(records.count) historical record(s)")
                return
            }
            self?.offload(records, from: bandID)
        }
    }

    /// Hands the batch to the store off the main actor; the main actor only converts and yields.
    private func offload(_ records: [BandProtocol.HistoricalRecord], from bandUUID: UUID) {
        guard !records.isEmpty else { return }
        BandLog.tierB(.info, "app: offload starting for \(records.count) record(s)")
        let database = database
        let nowMs = clock.nowMs
        Task.detached(priority: .utility) {
            await Self.storeHistoricalRecords(records, from: bandUUID, in: database, computedAtMs: nowMs)
        }
    }

    /// One write transaction per batch: insert the records (`INSERT OR IGNORE`, so a replayed batch
    /// dedups), then re-derive sleep for the drained window so the sessions replace their partial
    /// selves (PLAN.md 5.3.4, 8.1). Nonisolated, so the store work runs off the main actor.
    private nonisolated static func storeHistoricalRecords(
        _ records: [BandProtocol.HistoricalRecord],
        from bandUUID: UUID,
        in database: AppDatabase,
        computedAtMs: Int64
    ) async {
        let samples = records.map { record in
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
                signalQuality: raw(record.signalQuality)
            )
        }
        let fromMs = samples.map(\.tsMs).min() ?? 0
        let toMs = samples.map(\.tsMs).max() ?? 0
        do {
            try await database.writer.write { db in
                try db.insertHistoricalSamples(samples)
                guard let bandID = try String.fetchOne(
                    db, sql: "SELECT id FROM band WHERE peripheral_uuid = ?",
                    arguments: [bandUUID.uuidString]
                ) else {
                    BandLog.tierB(.error, "app: no band row for \(bandUUID.uuidString); records dropped")
                    return
                }
                let zone = try db.profile()?.timeZone ?? Dashboard.fallbackZone
                // Half-open to the millisecond past the last record, so it is included (PLAN.md 10.1).
                try db.deriveSleepSessions(
                    from: fromMs,
                    to: toMs + 1,
                    bandID: bandID,
                    in: zone,
                    computedAtMs: computedAtMs
                )
                BandLog.tierB(.info, "app: stored batch; sleep derivation succeeded")
            }
        } catch {
            // A failed batch is safe to drop: the strap replays it until its ack lands, and the
            // insert dedups on (band, timestamp) (PLAN.md 5.3.4).
            BandLog.tierB(.error, "app: storeHistoricalRecords failed: \(String(describing: error))")
        }
        #if DEBUG
        await Self.writeDebugDump(from: fromMs, to: toMs, in: database)
        #endif
    }

    #if DEBUG
    /// A consistent snapshot of the just-drained window plus the latest sessions, written as one
    /// JSON file. File copies of a live WAL database race with checkpoints, so a computer pulls
    /// this instead of `icarus.sqlite` to see what the app really stored.
    private nonisolated static func writeDebugDump(from fromMs: Int64, to toMs: Int64, in database: AppDatabase) async {
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

    /// A sensor raw byte for the store: 0 means the strap recorded nothing (PLAN.md 10.2 v2).
    private nonisolated static func raw(_ value: UInt16) -> Int? {
        value == 0 ? nil : Int(value)
    }

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
