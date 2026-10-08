import BandKit
import Foundation
import GRDB
import Metrics
import Store

/// Batches live readings into the store (PLAN.md 7.3). Readings are validated and written in one
/// transaction per flush, every 50 rows, every 5 s (driven by `.tick`), or when the app leaves the
/// foreground or the band disconnects (`.flush`). After each write, `MetricsWorker` recomputes the
/// closed minutes. Health values are never logged.
actor Ingestor {
    /// A notification from the band, with its receive time already stamped.
    struct Reading: Sendable, Equatable {
        let bandID: UUID
        let tsMs: Int64
        let bpm: Int
        let contact: Metrics.SensorContact?
        let rrMs: [Double]
    }

    enum Input: Sendable {
        case reading(Reading)
        case flush
        case tick
    }

    static let flushRowCount = 50
    /// Rows kept after a failed write. Older rows are dropped first, so memory stays bounded.
    static let retainedAfterFailure = 5_000

    private let database: AppDatabase
    private let metrics: MetricsWorker
    private let clock: AppClock
    private var preparer = ReadingPreparer()
    private var pending: [Database.Reading] = []

    init(database: AppDatabase, metrics: MetricsWorker, clock: AppClock) {
        self.database = database
        self.metrics = metrics
        self.clock = clock
    }

    /// Consumes inputs in arrival order until the stream finishes, then flushes what is left.
    func run(_ inputs: AsyncStream<Input>) async {
        for await input in inputs {
            switch input {
            case let .reading(reading):
                if let prepared = preparer.prepare(
                    peripheralUUID: reading.bandID,
                    tsMs: reading.tsMs,
                    bpm: reading.bpm,
                    contact: reading.contact,
                    rrMs: reading.rrMs
                ) {
                    pending.append(prepared)
                }
                if pending.count >= Self.flushRowCount {
                    await flush()
                }
            case .flush, .tick:
                await flush()
            }
        }
        await flush()
    }

    private func flush() async {
        guard !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        do {
            _ = try await database.writer.write { db in
                try db.insertReadings(batch)
            }
            _ = try await metrics.recompute(nowMs: clock.nowMs)
        } catch {
            pending.insert(contentsOf: batch, at: 0)
            if pending.count > Self.retainedAfterFailure {
                pending.removeFirst(pending.count - Self.retainedAfterFailure)
            }
        }
    }
}
