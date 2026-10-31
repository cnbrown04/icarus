import Foundation
import GRDB
import Metrics
import Testing
@testable import Store

@Suite("As-needed medications (no schedule, logged doses)")
struct AsNeededMedicationTests {
    private let chicago = TimeZone(identifier: "America/Chicago")!
    private let oct2 = LocalDay(year: 2026, month: 10, day: 2)
    private let oct5 = LocalDay(year: 2026, month: 10, day: 5)
    private let oct20 = LocalDay(year: 2026, month: 10, day: 20)

    /// A dose at 09:00 local on `day`, so it falls inside the October test range.
    private func dose(_ day: LocalDay) -> Int64 {
        LocalTime.localTime(day, minuteOfDay: 9 * 60, in: chicago)
    }

    private func asNeeded() -> MedicationProfile {
        MedicationProfile.Preset.amphetamineIR.profile(id: "adderall-ir", scheduleMinutesOfDay: [])
    }

    @Test func severalLoggedDosesPerDayCanBeListedAndOneRemoved() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            // Empty schedule: no doses unless a taken override exists for that day.
            try db.saveMedication(asNeeded(), nowMs: 1)
            try db.addDoseOverride(DoseOverride(medicationID: "adderall-ir", day: oct2, kind: .taken(atMs: 1_000)), nowMs: 2)
            try db.addDoseOverride(DoseOverride(medicationID: "adderall-ir", day: oct2, kind: .taken(atMs: 2_000)), nowMs: 3)
        }
        let entries = try database.writer.read { try $0.doseOverrideEntries(day: oct2) }
        #expect(entries.map(\.override.kind) == [.taken(atMs: 1_000), .taken(atMs: 2_000)])

        try database.writer.write { db in try db.deleteDoseOverride(id: entries[0].id) }
        let remaining = try database.writer.read { try $0.doseOverrideEntries(day: oct2) }
        #expect(remaining.map(\.override.kind) == [.taken(atMs: 2_000)])
    }

    @Test func asNeededMedicationHasWindowsOnlyForLoggedDoses() throws {
        let database = try AppDatabase.inMemory()
        try database.writer.write { db in
            try db.saveMedication(asNeeded(), nowMs: 1)
            try db.addDoseOverride(DoseOverride(medicationID: "adderall-ir", day: oct2, kind: .taken(atMs: dose(oct2))), nowMs: 2)
        }
        let windows = try database.writer.read {
            try $0.medicationWindows(from: oct2, to: oct5, in: chicago)
        }
        #expect(windows.count == 1)
        #expect(windows.first?.medicationID == "adderall-ir")
    }

}
