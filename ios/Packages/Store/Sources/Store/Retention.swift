import Foundation
import GRDB

/// Local retention windows (PLAN.md 10.2).
public enum RetentionPolicy {
    /// Raw HR and R-R are deleted only after this many days and only once acknowledged by the server.
    public static let rawDays: Int64 = 30
    public static let minuteDays: Int64 = 400
    public static let rawFrameHours: Int64 = 72
}

public struct RetentionResult: Sendable, Equatable {
    public let heartRateRows: Int
    public let rrRows: Int
    public let minuteRows: Int
    public let rawFrameRows: Int
}

extension Database {
    /// Deletes rows past their retention window (PLAN.md 10.2 "Local retention").
    ///
    /// Raw HR and R-R go only when older than 30 days and at or below the acknowledged cursor. In offline
    /// mode nothing is acknowledged, so raw rows stay. The row with the largest rowid is always kept:
    /// deleting it would let SQLite reuse a rowid below the cursor, and new rows would never sync.
    @discardableResult
    public func purgeExpired(nowMs: Int64) throws -> RetentionResult {
        let day: Int64 = 86_400_000
        let rawCutoff = nowMs - RetentionPolicy.rawDays * day
        let hr = try purgeAcknowledged(table: "hr_sample", stream: .hrSample, cutoff: rawCutoff)
        let rr = try purgeAcknowledged(table: "rr_interval", stream: .rrInterval, cutoff: rawCutoff)

        try execute(
            sql: "DELETE FROM minute_metric WHERE minute_ms < ?",
            arguments: [nowMs - RetentionPolicy.minuteDays * day]
        )
        let minutes = changesCount

        try execute(
            sql: "DELETE FROM raw_frame WHERE ts_ms < ?",
            arguments: [nowMs - RetentionPolicy.rawFrameHours * 3_600_000]
        )
        let frames = changesCount

        return RetentionResult(heartRateRows: hr, rrRows: rr, minuteRows: minutes, rawFrameRows: frames)
    }

    private func purgeAcknowledged(table: String, stream: SyncStream, cutoff: Int64) throws -> Int {
        let acknowledged = try syncCursor(stream)
        try execute(
            sql: """
            DELETE FROM \(table) WHERE ts_ms < ? AND rowid <= ?
              AND rowid < (SELECT MAX(rowid) FROM \(table))
            """,
            arguments: [cutoff, acknowledged]
        )
        return changesCount
    }
}
