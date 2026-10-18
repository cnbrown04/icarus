import Foundation
import GRDB

/// Streams with a row in `sync_cursor` (PLAN.md 10.2). `minuteMetric` tracks `sync_rev`, not rowid.
public enum SyncStream: String, Sendable, CaseIterable {
    case hrSample = "hr_sample"
    case rrInterval = "rr_interval"
    case minuteMetric = "minute_metric"
    case bandEvent = "band_event"
    case alarmDelivery = "alarm_delivery"
}

/// Sync cursor and batch log helpers (PLAN.md 11.3). Phase 3 reads a batch, uploads it, and advances the
/// cursor only after a 2xx response.
extension Database {
    /// The last rowid (or sync_rev) acknowledged for `stream`. Zero when nothing was acknowledged.
    public func syncCursor(_ stream: SyncStream) throws -> Int64 {
        try Int64.fetchOne(
            self,
            sql: "SELECT last_rowid FROM sync_cursor WHERE stream = ?",
            arguments: [stream.rawValue]
        ) ?? 0
    }

    /// Moves the cursor forward. It never moves back, so a late or repeated ack is harmless.
    public func advanceSyncCursor(_ stream: SyncStream, to position: Int64, succeededAtMs: Int64) throws {
        try execute(sql: """
        INSERT INTO sync_cursor (stream, last_rowid, last_success_at) VALUES (?, ?, ?)
        ON CONFLICT(stream) DO UPDATE SET
          last_rowid = MAX(last_rowid, excluded.last_rowid),
          last_success_at = excluded.last_success_at
        """, arguments: [stream.rawValue, position, succeededAtMs])
    }

    public func pendingHeartRateRows(after rowid: Int64, limit: Int) throws -> [HeartRateRow] {
        try HeartRateRow.fetchAll(self, sql: """
        SELECT * FROM hr_sample WHERE rowid > ? ORDER BY rowid LIMIT ?
        """, arguments: [rowid, limit])
    }

    public func pendingRRRows(after rowid: Int64, limit: Int) throws -> [RRIntervalRow] {
        try RRIntervalRow.fetchAll(self, sql: """
        SELECT * FROM rr_interval WHERE rowid > ? ORDER BY rowid LIMIT ?
        """, arguments: [rowid, limit])
    }

    public func pendingBandEventRows(after rowid: Int64, limit: Int) throws -> [BandEventRow] {
        try BandEventRow.fetchAll(self, sql: """
        SELECT * FROM band_event WHERE rowid > ? ORDER BY rowid LIMIT ?
        """, arguments: [rowid, limit])
    }

    public func pendingMinuteMetricRows(afterSyncRev revision: Int64, limit: Int) throws -> [MinuteMetricRow] {
        try MinuteMetricRow.fetchAll(self, sql: """
        SELECT * FROM minute_metric WHERE sync_rev > ? ORDER BY sync_rev LIMIT ?
        """, arguments: [revision, limit])
    }

    public func recordSyncBatch(id: String, createdAtMs: Int64, rows: Int, status: String) throws {
        try execute(
            sql: "INSERT INTO sync_batch_log (batch_id, created_at, rows, status) VALUES (?, ?, ?, ?)",
            arguments: [id, createdAtMs, rows, status]
        )
    }

    public func updateSyncBatch(id: String, status: String, httpStatus: Int?, error: String?) throws {
        try execute(
            sql: "UPDATE sync_batch_log SET status = ?, http_status = ?, error = ? WHERE batch_id = ?",
            arguments: [status, httpStatus, error, id]
        )
    }

    /// Batches, newest first. Pass `status` to list one state such as "rejected".
    public func syncBatches(status: String? = nil, limit: Int) throws -> [SyncBatchRow] {
        if let status {
            return try SyncBatchRow.fetchAll(self, sql: """
            SELECT * FROM sync_batch_log WHERE status = ? ORDER BY created_at DESC LIMIT ?
            """, arguments: [status, limit])
        }
        return try SyncBatchRow.fetchAll(self, sql: """
        SELECT * FROM sync_batch_log ORDER BY created_at DESC LIMIT ?
        """, arguments: [limit])
    }
}
