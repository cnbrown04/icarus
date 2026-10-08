import Foundation
import GRDB
import Store

/// Canned sync state for UI tests and screenshots (`-IcarusSyncFixture paired`). No request leaves the device.
public enum SyncFixture {
    public static let serverURL = URL(string: "https://icarus.example.com")!
    public static let deviceID = UUID(uuidString: "0192F6C1-7A3E-7C4D-9B1E-000000000D01")!
    public static let peripheral = UUID(uuidString: "6C1F3A10-2B7D-4E0A-9C11-0000000000B1")!

    /// Fills the store and outbox with a paired device: 60 heart-rate rows, 40 of them acknowledged, four acked
    /// batches and one quarantined batch. Returns an engine whose transport refuses every request.
    public static func seedPaired(
        database: AppDatabase,
        outbox: Outbox,
        tokens: any TokenStore,
        now: Date
    ) throws -> SyncEngine {
        try tokens.save("fixture-token")
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        var readings: [Database.Reading] = []
        for index in 0..<60 {
            let tsMs: Int64 = nowMs - Int64(60 - index) * 1000
            let bpm: Int = 60 + index % 9
            readings.append(Database.Reading(peripheralUUID: peripheral, tsMs: tsMs, bpm: bpm, contact: true, rr: []))
        }
        var quarantine: [QuarantineRecord] = []
        try database.writer.write { db in
            try db.insertReadings(readings)
            let firstBlock = try db.pendingHeartRateRows(after: 0, limit: 40)
            if let last = firstBlock.last {
                try db.advanceSyncCursor(.hrSample, to: last.rowid, succeededAtMs: nowMs)
            }
            let end = try db.pendingHeartRateRows(after: 0, limit: 100).last?.rowid ?? 0
            let from = [SyncStream.hrSample.rawValue: firstBlock.last?.rowid ?? 0]
            let to = [SyncStream.hrSample.rawValue: end]
            for index in 0..<4 {
                let id = "0192f6c1-7a3e-7c4d-9b1e-00000000000\(index)"
                try db.recordSyncBatch(id: id, createdAtMs: nowMs - Int64(index + 1) * 900_000, rows: 400, status: "pending")
                try db.updateSyncBatch(id: id, status: "acked", httpStatus: 200, error: nil)
            }
            let rejected = "0192f6c1-7a3e-7c4d-9b1e-000000000009"
            try db.recordSyncBatch(id: rejected, createdAtMs: nowMs - 600_000, rows: 20, status: "pending")
            try db.updateSyncBatch(
                id: rejected,
                status: "rejected",
                httpStatus: 422,
                error: "Column arrays differ in length"
            )
            quarantine.append(QuarantineRecord(batchID: rejected, from: from, to: to))
        }
        var state = OutboxState()
        state.connection = ServerConnection(serverURL: serverURL, deviceID: deviceID)
        state.pairedServer = serverURL
        state.lastSuccessAt = now.addingTimeInterval(-180)
        state.alarmsVersion = 12
        state.quarantine = quarantine
        state.sentThrough = [SyncStream.hrSample.rawValue: 60]
        try outbox.saveState(state)
        return SyncEngine(database: database, outbox: outbox, tokens: tokens, transport: OfflineTransport())
    }
}

/// Refuses every request. Used where the app must not reach the network.
public struct OfflineTransport: HTTPTransport {
    public init() {}

    public func perform(_ request: HTTPRequest) async throws -> HTTPResponse {
        throw APIError.network("Offline")
    }
}
