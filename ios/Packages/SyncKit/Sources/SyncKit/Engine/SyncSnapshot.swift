import Foundation
import GRDB
import Store

/// Counts for the Sync screen, read in one transaction.
public struct SyncSnapshot: Equatable, Sendable {
    /// Rows past the acknowledged cursors, across all streams.
    public let pendingRows: Int

    public static func load(_ db: Database) throws -> SyncSnapshot {
        var pending = 0
        for stream in SyncStream.allCases {
            let cursor = try db.syncCursor(stream)
            pending += try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM \(table(stream)) WHERE \(position(stream)) > ?",
                arguments: [cursor]
            ) ?? 0
        }
        return SyncSnapshot(pendingRows: pending)
    }

    private static func table(_ stream: SyncStream) -> String {
        switch stream {
        case .hrSample: "hr_sample"
        case .rrInterval: "rr_interval"
        case .minuteMetric: "minute_metric"
        case .bandEvent: "band_event"
        case .alarmDelivery: "alarm_delivery"
        }
    }

    private static func position(_ stream: SyncStream) -> String {
        stream == .minuteMetric ? "sync_rev" : "rowid"
    }
}
