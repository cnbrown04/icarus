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
        isSyncFixture: Bool
    ) {
        self.database = database
        self.clock = clock
        self.storageFailed = storageFailed
        self.ingestsLiveData = ingestsLiveData
        self.sync = sync
        self.isSyncFixture = isSyncFixture
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
                sync: makeSync(database: seeded, mode: .memory), isSyncFixture: false
            )
        }
        if config.syncFixture == "paired" {
            let database = inMemory()
            return AppEnvironment(
                database: database, clock: clock, storageFailed: false, ingestsLiveData: false,
                sync: makeSync(database: database, mode: .fixture(now: clock.now)), isSyncFixture: true
            )
        }
        if config.isUITest {
            let database = inMemory()
            return AppEnvironment(
                database: database, clock: clock, storageFailed: false, ingestsLiveData: true,
                sync: makeSync(database: database, mode: .memory), isSyncFixture: false
            )
        }
        if let url = storeURL(), let file = try? AppDatabase.file(at: url) {
            return AppEnvironment(
                database: file, clock: clock, storageFailed: false, ingestsLiveData: true,
                sync: makeSync(database: file, mode: .durable), isSyncFixture: false
            )
        }
        let database = inMemory()
        return AppEnvironment(
            database: database, clock: clock, storageFailed: true, ingestsLiveData: true,
            sync: makeSync(database: database, mode: .memory), isSyncFixture: false
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
