import Foundation
import GRDB
import Metrics
import Store

/// Owns the store, the clock and the ingestion pipeline. Built once at launch (PLAN.md 7.3, 7.4).
@MainActor
final class AppEnvironment {
    let database: AppDatabase
    let clock: AppClock
    /// True when the store could not open its file and runs in memory for this launch. Nothing is kept.
    let storageFailed: Bool

    private let metrics: MetricsWorker
    private let ingestor: Ingestor
    private let inputs: AsyncStream<Ingestor.Input>
    private let inputContinuation: AsyncStream<Ingestor.Input>.Continuation
    /// Seeded launches show fixed data, so live readings are not written over it.
    private let ingestsLiveData: Bool
    private var ingestionStarted = false

    private init(database: AppDatabase, clock: AppClock, storageFailed: Bool, ingestsLiveData: Bool) {
        self.database = database
        self.clock = clock
        self.storageFailed = storageFailed
        self.ingestsLiveData = ingestsLiveData
        let metrics = MetricsWorker(database: database)
        self.metrics = metrics
        self.ingestor = Ingestor(database: database, metrics: metrics, clock: clock)
        let (inputs, continuation) = AsyncStream.makeStream(of: Ingestor.Input.self)
        self.inputs = inputs
        self.inputContinuation = continuation
    }

    static func make(_ config: LaunchConfig) -> AppEnvironment {
        let clock = AppClock(fixedNow: config.fixedNow)
        if config.seedDB == "seed_30d", let seeded = try? SeedData.make30Days(now: clock.now) {
            return AppEnvironment(database: seeded, clock: clock, storageFailed: false, ingestsLiveData: false)
        }
        if config.isUITest {
            return AppEnvironment(database: inMemory(), clock: clock, storageFailed: false, ingestsLiveData: true)
        }
        if let url = storeURL(), let file = try? AppDatabase.file(at: url) {
            return AppEnvironment(database: file, clock: clock, storageFailed: false, ingestsLiveData: true)
        }
        return AppEnvironment(database: inMemory(), clock: clock, storageFailed: true, ingestsLiveData: true)
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
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return support.appendingPathComponent("Icarus", isDirectory: true).appendingPathComponent("icarus.sqlite")
    }

    private static func inMemory() -> AppDatabase {
        guard let database = try? AppDatabase.inMemory() else {
            preconditionFailure("An in-memory store always opens")
        }
        return database
    }
}
