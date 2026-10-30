import Foundation
import GRDB
import Metrics
import Testing
@testable import Store

@Suite("Medication store: profiles, overrides, windows (v8)")
struct MedicationStoreTests {
    private let chicago = TimeZone(identifier: "America/Chicago")!
    private let oct7 = LocalDay(year: 2026, month: 10, day: 7)
    private let oct8 = LocalDay(year: 2026, month: 10, day: 8)
    private let oct9 = LocalDay(year: 2026, month: 10, day: 9)

    /// Epoch ms for an ISO-8601 UTC instant such as "2026-10-08T13:00:00Z".
    private func ms(_ text: String) -> Int64 {
        Int64(ISO8601DateFormatter().date(from: text)!.timeIntervalSince1970 * 1000)
    }

    private func adderall(id: String = "adderall", schedule: [Int] = [480]) -> MedicationProfile {
        MedicationProfile.Preset.amphetamineIR.profile(id: id, scheduleMinutesOfDay: schedule)
    }

    @Test func profileRoundTripsThroughTheStore() throws {
        let database = try AppDatabase.inMemory()
        let profile = MedicationProfile(
            id: "m1", name: "Adderall (IR)", medClass: .stimulant, formulation: .immediateRelease,
            onsetMinutes: 30, durationMinutes: 300, scheduleMinutesOfDay: [480, 1200],
            weekdays: [2, 6], active: false
        )
        try database.writer.write { db in
            try db.saveMedication(profile, nowMs: 1_000)
        }
        let stored = try database.writer.read { try $0.medications() }
        #expect(stored == [profile])
    }

    @Test func savingAnExistingProfileUpdatesIt() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            try db.saveMedication(adderall(), nowMs: 1_000)
            try db.saveMedication(adderall(schedule: [540]), nowMs: 2_000)
        }
        let stored = try database.writer.read { try $0.medications() }
        #expect(stored.map(\.scheduleMinutesOfDay) == [[540]])
    }

    @Test func softDeletedProfileIsHiddenButKeptInTheTable() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            try db.saveMedication(adderall(), nowMs: 1_000)
            try db.deleteMedication(id: "adderall", nowMs: 2_000)
        }
        #expect(try database.writer.read { try $0.medications() }.isEmpty)
        let (deletedAt, updatedAt) = try database.writer.read { db -> (Int64?, Int64?) in
            let deleted = try Int64.fetchOne(db, sql: "SELECT deleted_at FROM medication WHERE id = 'adderall'")
            let updated = try Int64.fetchOne(db, sql: "SELECT updated_at FROM medication WHERE id = 'adderall'")
            return (deleted, updated)
        }
        #expect(deletedAt == 2_000)
        #expect(updatedAt == 2_000)
    }

    @Test func overridesAddListAndRemoveByDay() throws {
        let database = try AppDatabase.inMemory()
        let takenAt = ms("2026-10-08T15:10:00Z")
        try database.writer.write { db in
            try db.saveMedication(adderall(), nowMs: 1_000)
            try db.addDoseOverride(DoseOverride(medicationID: "adderall", day: oct8, kind: .taken(atMs: takenAt)), nowMs: 2_000)
            try db.addDoseOverride(DoseOverride(medicationID: "adderall", day: oct8, kind: .taken(atMs: takenAt + 3_600_000)), nowMs: 2_001)
            try db.addDoseOverride(DoseOverride(medicationID: "adderall", day: oct9, kind: .skipped), nowMs: 3_000)
        }
        let listed = try database.writer.read { try $0.doseOverrides(from: oct8, to: oct9) }
        #expect(listed == [
            DoseOverride(medicationID: "adderall", day: oct8, kind: .taken(atMs: takenAt)),
            DoseOverride(medicationID: "adderall", day: oct8, kind: .taken(atMs: takenAt + 3_600_000)),
            DoseOverride(medicationID: "adderall", day: oct9, kind: .skipped),
        ])

        try database.writer.write { db in
            try db.removeDoseOverrides(medicationID: "adderall", day: oct8)
        }
        let remaining = try database.writer.read { try $0.doseOverrides(from: oct7, to: oct9) }
        #expect(remaining == [DoseOverride(medicationID: "adderall", day: oct9, kind: .skipped)])
    }

    @Test func overrideRangeIsInclusiveOfBothDays() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            try db.saveMedication(adderall(), nowMs: 1_000)
            try db.addDoseOverride(DoseOverride(medicationID: "adderall", day: oct7, kind: .skipped), nowMs: 2_000)
            try db.addDoseOverride(DoseOverride(medicationID: "adderall", day: oct9, kind: .skipped), nowMs: 3_000)
        }
        let inRange = try database.writer.read { try $0.doseOverrides(from: oct8, to: oct9) }
        #expect(inRange.map(\.day) == [oct9])
    }

    @Test func checkConstraintRejectsATakenRowWithoutATime() throws {
        let database = try AppDatabase.inMemory()
        #expect(throws: DatabaseError.self) {
            try database.writer.write { db in
                try db.saveMedication(adderall(), nowMs: 1_000)
                try db.execute(sql: """
                INSERT INTO medication_dose_override (id, medication_id, local_day, kind, taken_at_ms, created_at)
                VALUES ('x', 'adderall', '2026-10-08', 'taken', NULL, 0)
                """)
            }
        }
    }

    @Test func windowsAreComputedFromScheduleAndOverrides() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            try db.saveMedication(adderall(), nowMs: 1_000)
            // Skip Oct 9 so only Oct 8 contributes.
            try db.addDoseOverride(DoseOverride(medicationID: "adderall", day: oct9, kind: .skipped), nowMs: 2_000)
        }
        let windows = try database.writer.read {
            try $0.medicationWindows(from: oct8, to: oct9, in: chicago)
        }
        // 08:00 CDT is 13:00Z; onset 30 min, then 300 min of effect.
        #expect(windows == [MedicationWindow(
            medicationID: "adderall", medClass: .stimulant,
            startMs: ms("2026-10-08T13:30:00Z"), endMs: ms("2026-10-08T18:30:00Z")
        )])
    }

    @Test func lateDoseThatRunsIntoTheRangeIsIncluded() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            // Adderall XR (onset 60, duration 660) at 23:00 each day.
            try db.saveMedication(
                MedicationProfile.Preset.amphetamineXR.profile(id: "xr", scheduleMinutesOfDay: [1380]),
                nowMs: 1_000
            )
        }
        let windows = try database.writer.read {
            try $0.medicationWindows(from: oct8, to: oct8, in: chicago)
        }
        // The Oct 7 dose at 23:00 CDT (04:00Z Oct 8) starts at 05:00Z and runs 11 h to 16:00Z.
        // The Oct 8 dose starts Oct 9 at 05:00Z, which is outside the range.
        #expect(windows == [MedicationWindow(
            medicationID: "xr", medClass: .stimulant,
            startMs: ms("2026-10-08T05:00:00Z"), endMs: ms("2026-10-08T16:00:00Z")
        )])
    }

    @Test func deletedProfileContributesNoWindows() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            try db.saveMedication(adderall(), nowMs: 1_000)
            try db.deleteMedication(id: "adderall", nowMs: 2_000)
        }
        let windows = try database.writer.read {
            try $0.medicationWindows(from: oct8, to: oct9, in: chicago)
        }
        #expect(windows.isEmpty)
    }
}

@Suite("Medication migration: v8 on top of v1–v7")
struct MedicationMigrationTests {
    /// A store that stopped at v7 keeps its rows, and opening it with the current schema adds v8.
    @Test func upgradingAV7StoreKeepsExistingRowsAndAddsTheTables() throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: configuration)

        var older = DatabaseMigrator()
        let through7 = [Schema.v1, Schema.v2, Schema.v3, Schema.v4, Schema.v5, Schema.v6, Schema.v7]
        for (index, sql) in through7.enumerated() {
            older.registerMigration("v\(index + 1)") { db in try db.execute(sql: sql) }
        }
        try older.migrate(queue)
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO band (id, peripheral_uuid, created_at) VALUES ('b1', 'peripheral-1', 0)
            """)
        }

        let database = try AppDatabase(writer: queue)
        let bands = try database.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM band") }
        #expect(bands == 1)
        let tables = try database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        #expect(tables.contains("medication"))
        #expect(tables.contains("medication_dose_override"))
        let applied = try database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
        #expect(applied.last == "v8")
    }
}
