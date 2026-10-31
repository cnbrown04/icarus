import Foundation
import GRDB
import Testing
@testable import Store

// Records dated before a band could have banked them (a wrong strap clock) are not kept.
@Suite("Band history reach")
struct BandHistoryReachTests {
    private let day: Int64 = 86_400_000

    @Test func theReachIsFifteenDaysBeforeTheBandWasFirstStored() throws {
        let database = try seededDatabase()
        let earliest = try database.writer.read { try $0.earliestRecordMs(peripheralUUID: testPeripheral, nowMs: 0) }
        #expect(earliest == testNowMs - 15 * day)
        let unknown = try database.writer.read { try $0.earliestRecordMs(peripheralUUID: UUID(), nowMs: testNowMs) }
        #expect(unknown == testNowMs - 15 * day)
    }

    @Test func purgeRemovesRecordsBeforeTheReachAndWhatCameFromThem() throws {
        let database = try seededDatabase()
        let band = try #require(database.writer.read { db in try String.fetchOne(db, sql: "SELECT id FROM band") })
        let old = testNowMs - 120 * day
        let recent = testNowMs - day
        try database.writer.write { db in
            for ts in [old, recent] {
                try db.execute(sql: "INSERT INTO historical_record (band_id, ts_ms, version, bpm) VALUES (?, ?, 24, 60)",
                               arguments: [band, ts])
                try db.execute(sql: """
                    INSERT INTO sleep_session (band_id, start_ms, end_ms, duration_s, contact_fraction, quality,
                      record_count, is_nap, algo_version, computed_at) VALUES (?, ?, ?, 3600, 1, 'good', 1, 0, 1, 0)
                    """, arguments: [band, ts - 3_600_000, ts])
                try db.execute(sql: """
                    INSERT INTO minute_metric (minute_ms, algo_version, computed_at, sync_rev) VALUES (?, 1, 0, 0)
                    """, arguments: [ts])
            }
            try db.purgeRecordsBeforeBandHistory()
        }
        let counts = try database.writer.read { db in
            try ["historical_record", "sleep_session", "minute_metric"].map { table in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1
            }
        }
        #expect(counts == [1, 1, 1])
        let kept = try database.writer.read { db in try Int64.fetchOne(db, sql: "SELECT ts_ms FROM historical_record") }
        #expect(kept == recent)
    }
}
