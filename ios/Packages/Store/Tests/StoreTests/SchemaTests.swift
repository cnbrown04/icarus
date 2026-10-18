import Foundation
import GRDB
import Testing
@testable import Store

struct SchemaTests {
    private static let tables = [
        "profile", "band", "hr_sample", "rr_interval", "minute_metric", "band_event",
        "alarm", "alarm_delivery", "sync_cursor", "sync_batch_log", "raw_frame",
    ]

    @Test func migratesEmptyDatabaseToV1Tables() throws {
        let database = try AppDatabase.inMemory()
        let names = try database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
        }
        #expect(Set(names) == Set(Self.tables + ["grdb_migrations"]))
    }

    @Test func recordsV1Migration() throws {
        let database = try AppDatabase.inMemory()
        let applied = try database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
        #expect(applied == ["v1"])
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
        #expect(count == 1)
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
