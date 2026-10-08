import Foundation
import GRDB
import Testing
@testable import Store

struct AlarmRepositoryTests {
    private func row(_ id: String, version: Int64 = 0, enabled: Bool = true) -> AlarmRow {
        AlarmRow(
            id: id,
            label: "Wake up",
            schedule: #"{"time":"06:30","weekdays":[1]}"#,
            rhythm: #""double""#,
            channels: #"["phone"]"#,
            enabled: enabled,
            version: version
        )
    }

    @Test func editIsDirtyAndKeepsTheServerVersion() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            try db.saveAlarmEdit(row("a1", version: 4), nowMs: 1_000)
        }
        let stored = try database.writer.read { try $0.alarm(id: "a1") }
        #expect(stored?.dirty == true)
        #expect(stored?.version == 4)
        #expect(stored?.updatedAt == 1_000)
        #expect(try database.writer.read { try $0.dirtyAlarms().map(\.id) } == ["a1"])
    }

    @Test func markCleanStopsTheRowBeingDirty() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            try db.saveAlarmEdit(row("a1"), nowMs: 1_000)
            try db.markAlarmClean(id: "a1")
        }
        #expect(try database.writer.read { try $0.dirtyAlarms() }.isEmpty)
        #expect(try database.writer.read { try $0.alarms().count } == 1)
    }

    @Test func deletingAnUnsentAlarmRemovesIt() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            try db.saveAlarmEdit(row("a1", version: 0), nowMs: 1_000)
            try db.deleteAlarmEdit(id: "a1", nowMs: 2_000)
        }
        #expect(try database.writer.read { try $0.alarm(id: "a1") } == nil)
    }

    @Test func deletingASyncedAlarmLeavesADirtyTombstone() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            try db.saveAlarmEdit(row("a1", version: 3), nowMs: 1_000)
            try db.markAlarmClean(id: "a1")
            try db.deleteAlarmEdit(id: "a1", nowMs: 2_000)
        }
        let tombstone = try database.writer.read { try $0.alarm(id: "a1") }
        #expect(tombstone?.deletedAt == 2_000)
        #expect(tombstone?.dirty == true)
        #expect(tombstone?.version == 3)
        // Tombstones leave the live list but stay in the dirty queue until the server confirms the delete.
        #expect(try database.writer.read { try $0.alarms() }.isEmpty)
        #expect(try database.writer.read { try $0.dirtyAlarms().map(\.id) } == ["a1"])
    }

    @Test func liveAlarmsKeepCreationOrder() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            try db.saveAlarmEdit(row("b"), nowMs: 1)
            try db.saveAlarmEdit(row("a"), nowMs: 2)
        }
        #expect(try database.writer.read { try $0.alarms().map(\.id) } == ["b", "a"])
    }

    @Test func seed30dHasThreeSyncedAlarms() throws {
        let database = try SeedData.make30Days(now: Date(timeIntervalSince1970: 1_791_383_400))
        let alarms = try database.writer.read { try $0.alarms() }
        #expect(alarms.map(\.label) == ["Wake up", "Weekend", "Stretch"])
        #expect(alarms.allSatisfy { !$0.dirty && $0.version == 1 })
        #expect(alarms.filter(\.enabled).count == 2)
    }
}
