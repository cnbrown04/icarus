import Foundation
import GRDB
import Metrics
import Testing
@testable import Store

/// Stress v3 in the store: medication edits mark stress stale, and the stimulant-near-sleep flag.
@Suite("Stress v3 store: medication recompute and stimulant-near-sleep flag")
struct StressMedicationStoreTests {
    private let chicago = TimeZone(identifier: "America/Chicago")!
    private let oct7 = LocalDay(year: 2026, month: 10, day: 7)

    private func storeMinuteSamples(into database: AppDatabase, endingAt nowMs: Int64, minutes: Int, bpm: Int) throws {
        let start = nowMs - Int64(minutes) * LocalTime.msPerMinute
        let readings = (0..<(minutes * 60)).map { index in
            Database.Reading(
                peripheralUUID: testPeripheral,
                tsMs: start + Int64(index) * 1000,
                bpm: bpm,
                contact: true,
                rr: []
            )
        }
        _ = try database.writer.write { try $0.insertReadings(readings) }
    }

    /// Minute rows whose stored algo_version is older than the current stress version.
    private func staleRowCount(_ database: AppDatabase) throws -> Int {
        let current = AlgoVersion.current.storedValue
        return try database.writer.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM minute_metric WHERE algo_version < ?", arguments: [current]) ?? 0
        }
    }

    @Test func saveMedicationMarksStressStaleAndRecomputeRewritesIt() async throws {
        let database = try seededDatabase()
        try storeMinuteSamples(into: database, endingAt: testNowMs, minutes: 30, bpm: 60)
        let worker = MetricsWorker(database: database)
        _ = try await worker.recompute(nowMs: testNowMs)
        #expect(try staleRowCount(database) == 0)

        let adderall = MedicationProfile.Preset.amphetamineIR.profile(id: "adderall", scheduleMinutesOfDay: [480])
        try await database.writer.write { try $0.saveMedication(adderall, nowMs: testNowMs) }
        #expect(try staleRowCount(database) == 30)

        let result = try await worker.recomputeStaleRows(nowMs: testNowMs)
        #expect(result.ran)
        #expect(result.changedRows >= 30)
        #expect(try staleRowCount(database) == 0)
    }

    @Test func deleteMedicationAndDoseOverrideAlsoMarkStale() async throws {
        let database = try seededDatabase()
        try storeMinuteSamples(into: database, endingAt: testNowMs, minutes: 30, bpm: 60)
        let worker = MetricsWorker(database: database)
        _ = try await worker.recompute(nowMs: testNowMs)
        let adderall = MedicationProfile.Preset.amphetamineIR.profile(id: "adderall", scheduleMinutesOfDay: [480])
        try await database.writer.write { try $0.saveMedication(adderall, nowMs: testNowMs) }
        #expect(try staleRowCount(database) == 30)
        _ = try await worker.recomputeStaleRows(nowMs: testNowMs)
        #expect(try staleRowCount(database) == 0)

        try await database.writer.write { try $0.deleteMedication(id: "adderall", nowMs: testNowMs) }
        #expect(try staleRowCount(database) == 30)
        _ = try await worker.recomputeStaleRows(nowMs: testNowMs)
        #expect(try staleRowCount(database) == 0)

        // An override marks its own day and the lookback days that read it. The minute rows sit on the
        // local day before today or today, so the override starts one day earlier to cover them either way.
        let today = LocalTime.localDay(containing: testNowMs, in: chicago)
        let overrideDay = LocalTime.adding(days: -1, to: today)
        try await database.writer.write {
            try $0.addDoseOverride(DoseOverride(medicationID: "adderall", day: overrideDay, kind: .skipped), nowMs: testNowMs)
        }
        #expect(try staleRowCount(database) > 0)
    }

    @Test func stimulantActiveJustBeforeSleepIsFlagged() throws {
        let database = try AppDatabase.inMemory()
        // Immediate-release dose at 22:45 with a 30 min onset: the stimulant starts 23:15, before the 23:30 sleep.
        let adderall = MedicationProfile.Preset.amphetamineIR.profile(id: "adderall", scheduleMinutesOfDay: [1365])
        try database.writer.write { try $0.saveMedication(adderall, nowMs: 1_000) }
        let sleepStart = LocalTime.localTime(oct7, minuteOfDay: 1410, in: chicago)
        let flagged = try database.writer.read {
            try $0.stimulantNearSleepOnset(sleepStartMs: sleepStart, in: chicago)
        }
        #expect(flagged)
    }

    @Test func stimulantEndedLongBeforeSleepIsNotFlagged() throws {
        let database = try AppDatabase.inMemory()
        // Dose at 09:00 with a 30 min onset and 5 h duration: the effect ends at 14:30, far from 23:30.
        let adderall = MedicationProfile.Preset.amphetamineIR.profile(id: "adderall", scheduleMinutesOfDay: [540])
        try database.writer.write { try $0.saveMedication(adderall, nowMs: 1_000) }
        let sleepStart = LocalTime.localTime(oct7, minuteOfDay: 1410, in: chicago)
        let flagged = try database.writer.read {
            try $0.stimulantNearSleepOnset(sleepStartMs: sleepStart, in: chicago)
        }
        #expect(!flagged)
    }

    @Test func stimulantEndingOneMinuteBeforeTheHourWindowIsNotFlagged() throws {
        let database = try AppDatabase.inMemory()
        // Dose at 20:30 with a 30 min onset and an 89 min duration: the window is 21:00 to 22:29. It ends one
        // minute before 22:30, the start of the hour before a 23:30 sleep, so it does not count.
        let profile = MedicationProfile(
            id: "short", name: "Short", medClass: .stimulant, formulation: .immediateRelease,
            onsetMinutes: 30, durationMinutes: 89, scheduleMinutesOfDay: [1230]
        )
        try database.writer.write { try $0.saveMedication(profile, nowMs: 1_000) }
        let sleepStart = LocalTime.localTime(oct7, minuteOfDay: 1410, in: chicago)
        let flagged = try database.writer.read {
            try $0.stimulantNearSleepOnset(sleepStartMs: sleepStart, in: chicago)
        }
        #expect(!flagged)
    }
}
