import Foundation
import GRDB
import Metrics
import Testing
@testable import Store

/// v4 persistence for the NOOP-V2 hypnogram: `sleep_stage_segment` write/read, idempotent replace,
/// totals, and derivation bounded to sessions touched by a drained range.
@Suite("Sleep stage segments")
struct SleepStageStoreTests {
    private static let utc = TimeZone(identifier: "UTC")!
    /// 2026-10-15T23:00:00Z, inside the night window.
    private let nightStart: Int64 = 1_792_105_200
    private var nightStartMs: Int64 { nightStart * 1000 }

    private func sample(_ tsMs: Int64, bpm: Int? = 55) -> Database.HistoricalSample {
        Database.HistoricalSample(
            peripheralUUID: testPeripheral,
            tsMs: tsMs,
            version: 24,
            bpm: bpm,
            contact: true,
            rrMs: [1_000, 1_010],
            respRateRaw: 3_073,
            signalQuality: 3_074,
            gravityX: 0.01,
            gravityY: -0.02,
            gravityZ: 0.999
        )
    }

    /// 240 two-minute records from 23:00 to 05:58 UTC.
    private func nightSamples() -> [Database.HistoricalSample] {
        stride(from: 0, to: 8 * 60 * 60, by: 120).map { offset in
            sample(nightStartMs + Int64(offset) * 1000)
        }
    }

    private func bandID(of database: AppDatabase) throws -> String {
        try #require(database.writer.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT id FROM band WHERE peripheral_uuid = ?",
                arguments: [testPeripheral.uuidString]
            )
        })
    }

    private func segment(_ start: Int64, _ end: Int64, _ stage: SleepStage) -> StageSegment {
        StageSegment(startUnix: start, endUnix: end, stage: stage)
    }

    // MARK: - Migration

    @Test func v4AddsTheStageTableAndSessionIndex() throws {
        let database = try AppDatabase.inMemory()
        let columns = try database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('sleep_stage_segment')")
        }
        #expect(Set(columns) == Set([
            "rowid", "band_id", "session_start_ms", "start_ms", "end_ms", "stage",
            "algo_version", "computed_at",
        ]))
        let indexes = try database.writer.read { db in
            try String.fetchAll(db, sql: """
            SELECT name FROM pragma_index_list('sleep_stage_segment')
            """)
        }
        #expect(indexes.contains("sleep_stage_segment_session"))
    }

    // MARK: - Write / read

    @Test func replaceRoundTripsAndIsIdempotent() throws {
        let database = try seededDatabase()
        let bandID = try bandID(of: database)
        let sessionStart = nightStartMs
        let start = nightStart
        let first: [StageSegment] = [
            segment(start, start + 1_800, .deep),
            segment(start + 1_800, start + 3_600, .light),
            segment(start + 3_600, start + 4_500, .wake),
        ]
        let written = try database.writer.write { db in
            try db.replaceSleepStageSegments(
                first, bandID: bandID, sessionStartMs: sessionStart, computedAtMs: testNowMs
            )
        }
        #expect(written == 3)

        let rows = try database.writer.read { db in
            try db.sleepStageSegmentRows(bandID: bandID, sessionStartMs: sessionStart)
        }
        #expect(rows.count == 3)
        #expect(rows.map(\.startMs) == first.map { $0.startUnix * 1000 })
        #expect(rows.map(\.endMs) == first.map { $0.endUnix * 1000 })
        #expect(rows.map(\.stage) == ["deep", "light", "wake"])
        #expect(rows.allSatisfy { $0.algoVersion == SleepStager.algoVersion })
        #expect(rows.allSatisfy { $0.computedAt == testNowMs })

        // Re-derivation replaces the whole session, never appends a second hypnogram.
        let second: [StageSegment] = [
            segment(start, start + 2_700, .light),
            segment(start + 2_700, start + 4_500, .rem),
        ]
        let replaced = try database.writer.write { db in
            try db.replaceSleepStageSegments(
                second, bandID: bandID, sessionStartMs: sessionStart, computedAtMs: testNowMs + 1_000
            )
        }
        #expect(replaced == 2)

        let reread = try database.writer.read { db in
            try db.sleepStageSegments(bandID: bandID, sessionStartMs: sessionStart)
        }
        #expect(reread == second)
    }

    @Test func emptyReplaceDeletesTheSessionsHypnogram() throws {
        let database = try seededDatabase()
        let bandID = try bandID(of: database)
        _ = try database.writer.write { db in
            try db.replaceSleepStageSegments(
                [segment(nightStart, nightStart + 600, .light)],
                bandID: bandID,
                sessionStartMs: nightStartMs,
                computedAtMs: testNowMs
            )
        }
        _ = try database.writer.write { db in
            try db.replaceSleepStageSegments(
                [],
                bandID: bandID,
                sessionStartMs: nightStartMs,
                computedAtMs: testNowMs
            )
        }
        let rows = try database.writer.read { db in
            try db.sleepStageSegments(bandID: bandID, sessionStartMs: nightStartMs)
        }
        #expect(rows.isEmpty)
    }

    @Test func readsAreScopedToSessionAndRange() throws {
        let database = try seededDatabase()
        let bandID = try bandID(of: database)
        let secondSessionStart = nightStart + 24 * 3_600
        _ = try database.writer.write { db in
            try db.replaceSleepStageSegments(
                [
                    segment(nightStart, nightStart + 3_600, .deep),
                    segment(nightStart + 3_600, nightStart + 7_200, .light),
                ],
                bandID: bandID,
                sessionStartMs: nightStartMs,
                computedAtMs: testNowMs
            )
            try db.replaceSleepStageSegments(
                [segment(secondSessionStart, secondSessionStart + 1_800, .rem)],
                bandID: bandID,
                sessionStartMs: secondSessionStart * 1000,
                computedAtMs: testNowMs
            )
        }

        let oneSession = try database.writer.read { db in
            try db.sleepStageSegments(bandID: bandID, sessionStartMs: nightStartMs)
        }
        #expect(oneSession.count == 2)
        #expect(oneSession.map(\.stage) == [.deep, .light])

        let inRange = try database.writer.read { db in
            try db.sleepStageSegments(
                bandID: bandID,
                from: (nightStart + 3_500) * 1000,
                to: (nightStart + 4_000) * 1000
            )
        }
        #expect(inRange.count == 2)
        #expect(inRange.map(\.stage) == [.deep, .light])
        #expect(inRange[0].endUnix == nightStart + 3_600, "a straddling segment is returned whole")

        let all = try database.writer.read { db in
            try db.sleepStageSegments(
                bandID: bandID,
                from: nightStartMs,
                to: (secondSessionStart + 2_000) * 1000
            )
        }
        #expect(all.map(\.stage) == [.deep, .light, .rem])
    }

    @Test func totalsSumStageSecondsAndAlwaysCarryAllFourStages() throws {
        let database = try seededDatabase()
        let bandID = try bandID(of: database)
        _ = try database.writer.write { db in
            try db.replaceSleepStageSegments(
                [
                    segment(nightStart, nightStart + 1_800, .deep),
                    segment(nightStart + 1_800, nightStart + 3_600, .light),
                    segment(nightStart + 3_600, nightStart + 4_200, .wake),
                ],
                bandID: bandID,
                sessionStartMs: nightStartMs,
                computedAtMs: testNowMs
            )
        }
        let totals = try database.writer.read { db in
            try db.sleepStageTotals(bandID: bandID, sessionStartMs: nightStartMs)
        }
        #expect(Set(totals.keys) == Set(SleepStage.allCases))
        #expect(totals[.deep] == 1_800)
        #expect(totals[.light] == 1_800)
        #expect(totals[.wake] == 600)
        #expect(totals[.rem] == 0)
    }

    // MARK: - Derivation

    @Test func derivationStagesTouchedSessionsAndCachesCurrentRows() throws {
        let database = try seededDatabase()
        _ = try database.writer.write { db in
            try db.insertHistoricalSamples(nightSamples())
        }
        let bandID = try bandID(of: database)
        let from = nightStartMs - 3_600_000
        let to = nightStartMs + 9 * 3_600_000

        let (sessions, written) = try database.writer.write { db -> ([SleepSessionRow], Int) in
            try db.deriveSleepSessions(
                from: from, to: to, bandID: bandID, in: Self.utc, computedAtMs: testNowMs
            )
            let sessions = try db.sleepSessionRows(bandID: bandID, from: from, to: to)
            let written = try db.deriveSleepStageSegments(
                from: from, to: to, bandID: bandID, computedAtMs: testNowMs
            )
            return (sessions, written)
        }
        let session = try #require(sessions.first)
        #expect(written > 0)

        let segments = try database.writer.read { db in
            try db.sleepStageSegments(bandID: bandID, sessionStartMs: session.startMs)
        }
        #expect(!segments.isEmpty)
        #expect(segments.first?.startUnix == session.startMs / 1000)
        #expect(segments.last?.endUnix == session.endMs / 1000)
        for index in 1..<segments.count {
            #expect(segments[index].startUnix == segments[index - 1].endUnix)
        }
        let rows = try database.writer.read { db in
            try db.sleepStageSegmentRows(bandID: bandID, sessionStartMs: session.startMs)
        }
        #expect(rows.allSatisfy { $0.algoVersion == SleepStager.algoVersion })

        // The same recipe already covers this exact window: no rows are rewritten.
        let secondPass = try database.writer.write { db in
            try db.deriveSleepStageSegments(
                from: from, to: to, bandID: bandID, computedAtMs: testNowMs + 60_000
            )
        }
        #expect(secondPass == 0)
    }

    @Test func derivationSkipsSessionsShorterThanTenMinutes() throws {
        let database = try seededDatabase()
        let bandID = try bandID(of: database)
        try database.writer.write { db in
            try db.execute(sql: """
            INSERT INTO sleep_session
              (band_id, start_ms, end_ms, duration_s, resting_hr, rmssd_ms, resp_rate_raw,
               skin_temp_raw, contact_fraction, quality, record_count, algo_version, computed_at)
            VALUES (?, ?, ?, ?, NULL, NULL, NULL, NULL, 1.0, 'good', 3, 1, ?)
            """, arguments: [bandID, nightStartMs, nightStartMs + 300_000, 300, testNowMs])
            try db.insertHistoricalSamples([
                sample(nightStartMs),
                sample(nightStartMs + 120_000),
                sample(nightStartMs + 240_000),
            ])
        }
        let written = try database.writer.write { db in
            try db.deriveSleepStageSegments(
                from: nightStartMs, to: nightStartMs + 300_000, bandID: bandID, computedAtMs: testNowMs
            )
        }
        #expect(written == 0)
        let rows = try database.writer.read { db in
            try db.sleepStageSegmentRows(bandID: bandID, sessionStartMs: nightStartMs)
        }
        #expect(rows.isEmpty)
    }
}
