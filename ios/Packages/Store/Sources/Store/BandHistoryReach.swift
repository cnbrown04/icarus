import Foundation
import GRDB

// How far back a band's records can truly reach. The strap banks history in a ring of 131,072 pages of about nine
// one-second records, about 13.6 days, so when a band is first stored here nothing it holds can be older than that,
// and everything it banks afterwards is newer. A record dated earlier was stamped by a strap clock that was wrong
// when it banked it: the first band's first sync (Oct 17, 2026) brought 134,105 records dated June 11–14, 2026,
// from before its clock was set. Their true time is unknown, so they are neither stored nor shown.

public enum BandHistoryReach {
    /// The ring's 13.6 days plus a day of margin.
    public static let ms: Int64 = 15 * 86_400_000
}

extension Database {
    /// The earliest `ts_ms` a record from this band can truly carry: `BandHistoryReach.ms` before the band was first
    /// stored here, or before `nowMs` for a band not stored yet (its first record is being stored now).
    public func earliestRecordMs(peripheralUUID: UUID, nowMs: Int64) throws -> Int64 {
        let createdAt = try Int64.fetchOne(self, sql: "SELECT created_at FROM band WHERE peripheral_uuid = ?",
                                           arguments: [peripheralUUID.uuidString])
        return (createdAt ?? nowMs) - BandHistoryReach.ms
    }

    /// Deletes every record dated before its band's reach, and what was derived from them: minute metrics, sleep
    /// sessions and their stages, and cached day scores before the earliest band's reach. Returns the number of
    /// band records deleted. Safe to repeat.
    @discardableResult
    public func purgeRecordsBeforeBandHistory() throws -> Int {
        let reach = BandHistoryReach.ms
        try execute(sql: """
            DELETE FROM historical_record WHERE ts_ms < (SELECT created_at - ? FROM band WHERE band.id = historical_record.band_id)
            """, arguments: [reach])
        let records = changesCount
        var tables = [("hr_sample", "ts_ms"), ("rr_interval", "ts_ms"), ("sleep_session", "end_ms"),
                      ("sleep_stage_segment", "end_ms")]
        // `night_reading` arrives in v13, after the v12 run of this cleanup.
        if try tableExists("night_reading") { tables.append(("night_reading", "ts_ms")) }
        for (table, column) in tables {
            try execute(sql: """
                DELETE FROM \(table) WHERE \(column) < (SELECT created_at - ? FROM band WHERE band.id = \(table).band_id)
                """, arguments: [reach])
        }
        // Minute metrics and day scores carry no band; the earliest band's reach bounds them.
        guard let earliest = try Int64.fetchOne(self, sql: "SELECT MIN(created_at) - ? FROM band", arguments: [reach])
        else { return records }
        try execute(sql: "DELETE FROM minute_metric WHERE minute_ms < ?", arguments: [earliest])
        try execute(sql: "DELETE FROM daily_score WHERE local_day < date(? / 1000, 'unixepoch')", arguments: [earliest])
        return records
    }
}
