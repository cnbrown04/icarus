import Foundation
import GRDB
import Metrics
import Testing
@testable import Store

/// v6 sleep corrections: a retimed bed/wake or a deleted night must survive every re-derivation,
/// and the guard rails must refuse a window that could not be a real night.
@Suite("Sleep edits")
struct SleepEditTests {
    private static let utc = TimeZone(identifier: "UTC")!

    /// 2026-10-15T23:00:00Z, inside the night window.
    private let nightStart: Int64 = 1_792_105_200
    private var nightStartMs: Int64 { nightStart * 1000 }
    /// The night's detected end: the last 2-minute record, 06:58 the next morning.
    private var nightEndMs: Int64 { nightStartMs + (8 * 60 * 60 - 120) * 1000 }
    /// "Now" is 11:00 the next morning, after the whole test night has been recorded.
    private var nowMs: Int64 { nightStartMs + 12 * 3_600_000 }
    private var rangeFromMs: Int64 { nightStartMs - 3_600_000 }
    private var rangeToMs: Int64 { nightStartMs + 9 * 3_600_000 }

    private func sample(_ tsMs: Int64, contact: Bool = true) -> Database.HistoricalSample {
        Database.HistoricalSample(
            peripheralUUID: testPeripheral,
            tsMs: tsMs,
            version: 24,
            bpm: 55,
            contact: contact,
            rrMs: [1_000, 1_010],
            gravityX: 0.012,
            gravityY: -0.031,
            gravityZ: 0.999
        )
    }

    /// 240 two-minute records from 23:00 to 06:58 UTC: one still, on-wrist night.
    private func nightSamples(contact: @escaping (Int) -> Bool = { _ in true }) -> [Database.HistoricalSample] {
        stride(from: 0, to: 8 * 60 * 60, by: 120).map { offset in
            sample(nightStartMs + Int64(offset) * 1000, contact: contact(offset))
        }
    }

    private func bandID(of database: AppDatabase) throws -> String {
        try #require(database.writer.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM band WHERE peripheral_uuid = ?", arguments: [testPeripheral.uuidString])
        })
    }

    /// A seeded database holding one detected night, derived once.
    private func databaseWithDetectedNight(contact: @escaping (Int) -> Bool = { _ in true }) throws -> (AppDatabase, String) {
        let database = try seededDatabase()
        _ = try database.writer.write { db in
            try db.insertHistoricalSamples(nightSamples(contact: contact))
        }
        let bandID = try bandID(of: database)
        _ = try rederive(database, bandID)
        return (database, bandID)
    }

    /// What the app does on every drain: sessions, then hypnograms, over the standard range.
    @discardableResult
    private func rederive(_ database: AppDatabase, _ bandID: String) throws -> [SleepSessionRow] {
        try database.writer.write { db in
            try db.deriveSleepSessions(from: rangeFromMs, to: rangeToMs, bandID: bandID, in: Self.utc, computedAtMs: testNowMs)
            try db.deriveSleepStageSegments(from: rangeFromMs, to: rangeToMs, bandID: bandID, computedAtMs: testNowMs)
            return try db.sleepSessionRows(bandID: bandID, from: rangeFromMs, to: rangeToMs)
        }
    }

    private func retime(
        _ database: AppDatabase,
        _ bandID: String,
        from start: Int64,
        to end: Int64,
        displayed: (start: Int64, end: Int64)? = nil
    ) throws {
        let shown = displayed ?? (nightStartMs, nightEndMs)
        try database.writer.write { db in
            try db.retimeSleepSession(
                bandID: bandID,
                sessionStartMs: shown.start,
                sessionEndMs: shown.end,
                newStartMs: start,
                newEndMs: end,
                in: Self.utc,
                nowMs: nowMs
            )
        }
    }

    /// Bed 23:30, wake 06:00: a 6 h 30 min night inside the detected one.
    private var trimmedStartMs: Int64 { nightStartMs + 30 * 60_000 }
    private var trimmedEndMs: Int64 { nightStartMs + 7 * 3_600_000 }

    // MARK: Migration

    @Test func v6CreatesTheEditTable() throws {
        let database = try AppDatabase.inMemory()
        let columns = try database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('sleep_edit')")
        }
        #expect(Set(columns) == Set([
            "rowid", "band_id", "original_start_ms", "original_end_ms", "new_start_ms", "new_end_ms",
            "kind", "created_at",
        ]))
        let applied = try database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
        }
        #expect(applied.contains("v6"))
    }

    @Test func theKindColumnRejectsUnknownValues() throws {
        let database = try seededDatabase()
        let bandID = try bandID(of: database)
        #expect(throws: DatabaseError.self) {
            _ = try database.writer.write { db in
                try db.execute(sql: """
                INSERT INTO sleep_edit (band_id, original_start_ms, original_end_ms, new_start_ms, kind, created_at)
                VALUES (?, 1, 2, 1, 'merge', 0)
                """, arguments: [bandID])
            }
        }
    }

    // MARK: Retime

    @Test func retimePersistsAcrossReDerive() throws {
        let (database, bandID) = try databaseWithDetectedNight()
        try retime(database, bandID, from: trimmedStartMs, to: trimmedEndMs)

        // A later drain re-detects the original night and replaces the stored sessions.
        let sessions = try rederive(database, bandID)
        #expect(sessions.count == 1)
        let session = try #require(sessions.first)
        #expect(session.startMs == trimmedStartMs)
        #expect(session.endMs == trimmedEndMs)
        #expect(session.durationS == 6 * 3600 + 1800)

        // The detected start's row and hypnogram are gone, not left beside the corrected one.
        let staleCount = try database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sleep_session WHERE band_id = ? AND start_ms = ?",
                             arguments: [bandID, nightStartMs]) ?? 0
        }
        #expect(staleCount == 0)

        let edits = try database.writer.read { db in try db.sleepEdits(bandID: bandID) }
        #expect(edits.count == 1)
        #expect(edits.first?.kindValue == .retime)
        #expect(edits.first?.originalStartMs == nightStartMs)
        #expect(edits.first?.originalEndMs == nightEndMs)
    }

    @Test func retimeRestagesTheHypnogramToTheNewBounds() throws {
        let (database, bandID) = try databaseWithDetectedNight()
        try retime(database, bandID, from: trimmedStartMs, to: trimmedEndMs)
        _ = try rederive(database, bandID)

        let segments = try database.writer.read { db in
            try db.sleepStageSegments(bandID: bandID, sessionStartMs: trimmedStartMs)
        }
        #expect(!segments.isEmpty)
        #expect(segments.first?.startUnix == trimmedStartMs / 1000)
        #expect(segments.last?.endUnix == trimmedEndMs / 1000)
        let oldSegments = try database.writer.read { db in
            try db.sleepStageSegments(bandID: bandID, sessionStartMs: nightStartMs)
        }
        #expect(oldSegments.isEmpty)
    }

    @Test func aRetimedSummaryReflectsOnlyTheRecordsInsideTheNewBounds() throws {
        // Records outside the trimmed window are off-wrist, so a summary that still reached them
        // would show a lower contact fraction and a fair quality.
        let trimmedRange = (30 * 60)...(7 * 3600)
        let (database, bandID) = try databaseWithDetectedNight { offset in
            trimmedRange.contains(offset)
        }
        try retime(database, bandID, from: trimmedStartMs, to: trimmedEndMs)

        let session = try #require(try rederive(database, bandID).first)
        // Records at 23:30 through 06:00 inclusive, every 2 minutes: 196 of them.
        #expect(session.recordCount == 196)
        #expect(session.contactFraction == 1)
        #expect(session.qualityValue == .good)
    }

    @Test func aCorrectionSurvivesADerivationOverOnlyItsNewSpan() throws {
        let (database, bandID) = try databaseWithDetectedNight()
        try retime(database, bandID, from: trimmedStartMs, to: trimmedEndMs)

        // A drain touching only the corrected bed time must keep the corrected night, not drop it as stale.
        try database.writer.write { db in
            _ = try db.deriveSleepSessions(
                from: trimmedStartMs - 3_600_000, to: trimmedStartMs + 3_600_000,
                bandID: bandID, in: Self.utc, computedAtMs: testNowMs
            )
        }
        let sessions = try database.writer.read { db in
            try db.sleepSessionRows(bandID: bandID, from: rangeFromMs, to: rangeToMs)
        }
        #expect(sessions.map(\.startMs) == [trimmedStartMs])
    }

    @Test func secondCorrectionKeepsTheDetectedWindowAsItsOriginal() throws {
        let (database, bandID) = try databaseWithDetectedNight()
        try retime(database, bandID, from: trimmedStartMs, to: trimmedEndMs)
        // The screen now shows the corrected night, so the second correction starts from it.
        try retime(
            database, bandID,
            from: nightStartMs + 45 * 60_000, to: trimmedEndMs,
            displayed: (trimmedStartMs, trimmedEndMs)
        )

        let edits = try database.writer.read { db in try db.sleepEdits(bandID: bandID) }
        #expect(edits.count == 1)
        #expect(edits.first?.originalStartMs == nightStartMs)
        #expect(edits.first?.newStartMs == nightStartMs + 45 * 60_000)
    }

    // MARK: Dismiss

    @Test func dismissPersistsAcrossReDerive() throws {
        let (database, bandID) = try databaseWithDetectedNight()
        try database.writer.write { db in
            try db.dismissSleepSession(
                bandID: bandID, sessionStartMs: nightStartMs, sessionEndMs: nightEndMs, in: Self.utc, nowMs: nowMs
            )
        }
        #expect(try rederive(database, bandID).isEmpty)
        #expect(try rederive(database, bandID).isEmpty)

        let (sessions, segments, edits) = try database.writer.read { db in
            (
                try db.sleepSessionRows(bandID: bandID, from: rangeFromMs, to: rangeToMs),
                try db.sleepStageSegmentRows(bandID: bandID, sessionStartMs: nightStartMs),
                try db.sleepEdits(bandID: bandID)
            )
        }
        #expect(sessions.isEmpty)
        #expect(segments.isEmpty)
        #expect(edits.map(\.kindValue) == [.dismiss])
        #expect(edits.first?.newEndMs == nil)
    }

    @Test func removingACorrectionRestoresTheDetectedNight() throws {
        let (database, bandID) = try databaseWithDetectedNight()
        try retime(database, bandID, from: trimmedStartMs, to: trimmedEndMs)

        let removed = try database.writer.write { db in
            try db.removeSleepEdit(
                bandID: bandID, sessionStartMs: trimmedStartMs, sessionEndMs: trimmedEndMs, in: Self.utc, nowMs: nowMs
            )
        }
        #expect(removed)
        let sessions = try rederive(database, bandID)
        #expect(sessions.map(\.startMs) == [nightStartMs])
        #expect(sessions.first?.endMs == nightEndMs)

        let again = try database.writer.write { db in
            try db.removeSleepEdit(
                bandID: bandID, sessionStartMs: trimmedStartMs, sessionEndMs: trimmedEndMs, in: Self.utc, nowMs: nowMs
            )
        }
        #expect(!again)
    }

    @Test func removingADismissalBringsTheNightBack() throws {
        let (database, bandID) = try databaseWithDetectedNight()
        try database.writer.write { db in
            try db.dismissSleepSession(
                bandID: bandID, sessionStartMs: nightStartMs, sessionEndMs: nightEndMs, in: Self.utc, nowMs: nowMs
            )
        }
        _ = try database.writer.write { db in
            try db.removeSleepEdit(
                bandID: bandID, sessionStartMs: nightStartMs, sessionEndMs: nightEndMs, in: Self.utc, nowMs: nowMs
            )
        }
        #expect(try rederive(database, bandID).map(\.startMs) == [nightStartMs])
    }

    // MARK: Guard rails

    @Test func retimeRefusesAnInvertedOrEmptyWindow() throws {
        let (database, bandID) = try databaseWithDetectedNight()
        #expect(throws: SleepEditError.endNotAfterStart) {
            try self.retime(database, bandID, from: trimmedEndMs, to: trimmedStartMs)
        }
        #expect(throws: SleepEditError.endNotAfterStart) {
            try self.retime(database, bandID, from: trimmedStartMs, to: trimmedStartMs)
        }
    }

    @Test func retimeRefusesANightShorterThanThirtyMinutes() throws {
        let (database, bandID) = try databaseWithDetectedNight()
        #expect(throws: SleepEditError.durationOutOfRange) {
            try self.retime(database, bandID, from: trimmedStartMs, to: trimmedStartMs + 20 * 60_000)
        }
    }

    @Test func retimeRefusesANightLongerThanSixteenHours() throws {
        let (database, bandID) = try databaseWithDetectedNight()
        #expect(throws: SleepEditError.durationOutOfRange) {
            try self.retime(database, bandID, from: nightStartMs, to: nightStartMs + 17 * 3_600_000)
        }
    }

    @Test func retimeRefusesAWakeTimeInTheFuture() throws {
        let (database, bandID) = try databaseWithDetectedNight()
        // Ends an hour after "now", beyond the five-minute clock-skew allowance.
        #expect(throws: SleepEditError.endsInTheFuture) {
            try self.retime(database, bandID, from: nightStartMs + 3_600_000, to: nowMs + 3_600_000)
        }
    }

    @Test func retimeAllowsASmallClockSkewIntoTheFuture() throws {
        let (database, bandID) = try databaseWithDetectedNight()
        try retime(database, bandID, from: trimmedStartMs, to: nowMs + 60_000)
    }

    @Test func retimeRefusesAWindowThatOverlapsAnotherNight() throws {
        let (database, bandID) = try databaseWithDetectedNight()
        // Another stored night 8 h 20 min to 9 h 27 min after the detected start, past the detected wake.
        try database.writer.write { db in
            try db.execute(sql: """
            INSERT INTO sleep_session
              (band_id, start_ms, end_ms, duration_s, contact_fraction, quality, record_count, algo_version, computed_at)
            VALUES (?, ?, ?, 3600, 1.0, 'good', 30, 2, ?)
            """, arguments: [bandID, nightStartMs + 30_000_000, nightStartMs + 34_000_000, testNowMs])
        }
        // Moving the wake time to 9 h 10 min after the start runs into that night.
        #expect(throws: SleepEditError.overlapsAnotherNight) {
            try self.retime(database, bandID, from: trimmedStartMs, to: nightStartMs + 33_000_000)
        }
        let edits = try database.writer.read { db in try db.sleepEdits(bandID: bandID) }
        #expect(edits.isEmpty)
    }

    @Test func retimeRefusesAWindowWithNoRecordedData() throws {
        let (database, bandID) = try databaseWithDetectedNight()
        // Two hours before the band ever recorded this night.
        #expect(throws: SleepEditError.noRecordedData) {
            try self.retime(
                database, bandID,
                from: nightStartMs - 10 * 3_600_000, to: nightStartMs - 8 * 3_600_000
            )
        }
    }

    @Test func aRefusedCorrectionWritesNothing() throws {
        let (database, bandID) = try databaseWithDetectedNight()
        #expect(throws: SleepEditError.durationOutOfRange) {
            try self.retime(database, bandID, from: trimmedStartMs, to: trimmedStartMs + 60_000)
        }
        let edits = try database.writer.read { db in try db.sleepEdits(bandID: bandID) }
        #expect(edits.isEmpty)
        #expect(try rederive(database, bandID).map(\.startMs) == [nightStartMs])
    }
}
