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

    @Test func tookBehaviourIsYesOnlyOnLoggedDays() throws {
        let database = try seededDatabase()
        try database.writer.write { db in
            // Morning of each day Sep 30 - Oct 13 carries a sleep with HRV 40 ms.
            for index in 1...13 {
                let end = LocalTime.localTime(LocalDay(year: 2026, month: 10, day: index), hour: 7, in: chicago)
                try db.execute(sql: """
                INSERT INTO sleep_session (band_id, start_ms, end_ms, duration_s, rmssd_ms, contact_fraction, quality,
                  record_count, algo_version, computed_at, is_nap)
                SELECT id, ?, ?, 25200, 40, 1.0, 'good', 1, 1, 0, 0 FROM band
                """, arguments: [end - 7 * 3_600_000, end])
            }
            try db.saveMedication(asNeeded(), nowMs: 1)
            try db.addDoseOverride(DoseOverride(medicationID: "adderall-ir", day: oct2, kind: .taken(atMs: dose(oct2))), nowMs: 2)
            try db.addDoseOverride(DoseOverride(medicationID: "adderall-ir", day: oct5, kind: .taken(atMs: dose(oct5))), nowMs: 3)
        }
        let insights = try database.writer.read { try $0.journalInsights(through: oct20, in: chicago) }
        let took = try #require(insights.first {
            $0.behaviourID == "medication:adderall-ir" && $0.effect.metric == .hrv
        })
        #expect(took.effect.with.days == 2)
        // Sep 30 and Oct 1, 3, 4, 6-12: every other window day with a morning after it.
        #expect(took.effect.without.days == 11)
    }
}
