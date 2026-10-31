import Foundation
import GRDB
import Testing
@testable import Store

struct SchemaTests {
    private static let tables = [
        "profile", "band", "hr_sample", "rr_interval", "minute_metric", "band_event",
        "alarm", "alarm_delivery", "sync_cursor", "sync_batch_log", "raw_frame",
        "historical_record", "sleep_session", "sleep_stage_segment", "sleep_edit",
        "medication", "medication_dose_override", "activity", "journal_question", "journal_entry",
    ]
    /// v2 added the sleep tables, v3 the nine nullable `historical_record` sensor columns, v4 the
    /// persisted sleep-stage segments, v5 the nap flag on `sleep_session`, v6 the user sleep
    /// corrections (`sleep_edit`), v7 the nightly respiratory rate on `sleep_session`, v8 the
    /// medication profiles and dose overrides, v9 the `activity` table, v10 the journal questions and answers.
    private static let migrations = ["v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9", "v10"]

    @Test func migratesEmptyDatabaseToAllTables() throws {
        let database = try AppDatabase.inMemory()
        let names = try database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
        }
        #expect(Set(names) == Set(Self.tables + ["grdb_migrations"]))
    }

    @Test func recordsEveryMigration() throws {
        let database = try AppDatabase.inMemory()
        let applied = try database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
        #expect(applied == Self.migrations.sorted())
    }

    @Test func reopeningAFileDatabaseDoesNotRerunMigrations() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("icarus.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        _ = try AppDatabase.file(at: url)
        let reopened = try AppDatabase.file(at: url)
        let count = try reopened.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations")
        }
        #expect(count == Self.migrations.count)
    }

    @Test func v3AddsTheNullableSensorColumns() throws {
        let database = try AppDatabase.inMemory()
        let columns = try database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('historical_record')")
        }
        for column in ["gravity_x", "gravity_y", "gravity_z", "gravity2_x", "gravity2_y", "gravity2_z",
                       "ambient_drive", "led_drive1", "led_drive2"] {
            #expect(columns.contains(column), "missing column \(column)")
        }
        // The v2 dedup constraint survives the additive migration.
        let constraints = try database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT sql FROM sqlite_master WHERE name = 'historical_record'")
        }
        #expect(constraints.first?.contains("UNIQUE (band_id, ts_ms)") == true)
    }

    @Test func v5AddsTheNapFlagDefaultingToMainSleep() throws {
        let database = try seededDatabase()
        let columns = try database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('sleep_session')")
        }
        #expect(columns.contains("is_nap"))
        // A row written without the flag (as a pre-v5 row is, after the migration) reads as a main sleep.
        _ = try database.writer.write { db in
            try db.execute(sql: """
            INSERT INTO sleep_session (band_id, start_ms, end_ms, duration_s, contact_fraction, quality,
              record_count, algo_version, computed_at)
            SELECT id, 1000, 2000, 1, 1.0, 'good', 1, 3, 0 FROM band
            """)
        }
        let isNap = try database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT is_nap FROM sleep_session")
        }
        #expect(isNap == 0)
    }

    @Test func v7AddsTheRespiratoryRateColumn() throws {
        let database = try AppDatabase.inMemory()
        let columns = try database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('sleep_session')")
        }
        #expect(columns.contains("resp_rate_brpm"))
    }

    @Test func profileIsSingleRowWithCheckConstraint() throws {
        let database = try AppDatabase.inMemory()
        #expect(throws: DatabaseError.self) {
            _ = try database.writer.write { db in
                try db.execute(sql: "INSERT INTO profile (id, updated_at) VALUES (2, 0)")
            }
        }
    }

    @Test func heartRateRejectsBpmOutsideCheckRange() throws {
        let database = try AppDatabase.inMemory()
        #expect(throws: DatabaseError.self) {
            _ = try database.writer.write { db in
                try db.upsertBand(peripheralUUID: UUID(), name: nil, seenAtMs: 0)
                try db.execute(sql: "INSERT INTO hr_sample (band_id, ts_ms, bpm, source) SELECT id, 1, 251, 1 FROM band")
            }
        }
    }
}
