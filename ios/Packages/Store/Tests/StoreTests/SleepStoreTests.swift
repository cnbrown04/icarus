import Foundation
import GRDB
import Metrics
import Testing
@testable import Store

// The v2 tables: historical_record (deduped offload ingest) and sleep_session (derived nightly
// sessions). See Schema.v2 for the column rationale.
@Suite("History offload and sleep sessions")
struct SleepStoreTests {
    private static let utc = TimeZone(identifier: "UTC")!

    /// 2026-10-15T23:00:00Z, inside the night window.
    private let nightStart: Int64 = 1_792_105_200
    /// The same instant in ms (PLAN.md 10.1 stores ts_ms; the record itself is second-granular).
    private var nightStartMs: Int64 { nightStart * 1000 }

    private func sample(_ tsMs: Int64, bpm: Int? = 55, contact: Bool = true, rr: [Double] = [1_000, 1_010]) -> Database.HistoricalSample {
        Database.HistoricalSample(
            peripheralUUID: testPeripheral,
            tsMs: tsMs,
            version: 24,
            bpm: bpm,
            contact: contact,
            rrMs: rr,
            ppgGreen: 15_840,
            ppgRedIr: 17_940,
            spo2Red: 8_000,
            spo2Ir: 12_000,
            skinTempRaw: 3_900,
            respRateRaw: 660,
            signalQuality: 240,
            gravityX: 0.012,
            gravityY: -0.031,
            gravityZ: 0.999,
            gravity2X: 0.002,
            gravity2Y: -0.004,
            gravity2Z: 1.005,
            ambientDrive: 7,
            ledDrive1: 1_204,
            ledDrive2: 1_310
        )
    }

    /// 240 two-minute records from 23:00 to 06:58 UTC with a fixed wrist vector: eight still,
    /// on-wrist hours that `SleepDetector` reads as one night.
    private func nightSamples() -> [Database.HistoricalSample] {
        stride(from: 0, to: 8 * 60 * 60, by: 120).map { offset in
            sample(nightStartMs + offset * 1000)
        }
    }

    private func storedBandID(of database: AppDatabase) throws -> String {
        try #require(database.writer.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM band WHERE peripheral_uuid = ?", arguments: [testPeripheral.uuidString])
        })
    }

    private func insertNight(_ database: AppDatabase) throws {
        _ = try database.writer.write { db in
            try db.insertHistoricalSamples(nightSamples())
        }
    }

    @Test func samplesAreDedupedByBandAndTimestamp() throws {
        let database = try seededDatabase()
        let inserted = try database.writer.write { db in
            try db.insertHistoricalSamples([sample(nightStartMs)])
        }
        #expect(inserted == 1)

        let replayed = try database.writer.write { db in
            try db.insertHistoricalSamples([sample(nightStartMs), sample(nightStartMs + 120_000)])
        }
        #expect(replayed == 1) // the first sample deduped, the new one inserted

        let rows = try database.writer.read { db in
            try HistoricalRecordRow.fetchAll(db, sql: "SELECT * FROM historical_record ORDER BY ts_ms")
        }
        #expect(rows.count == 2)
        #expect(rows[0].tsMs == nightStartMs)
        #expect(rows[1].tsMs == nightStartMs + 120_000)
    }

    @Test func sampleFieldsRoundTrip() throws {
        let database = try seededDatabase()
        _ = try database.writer.write { db in
            try db.insertHistoricalSamples([sample(nightStartMs, bpm: nil, contact: false, rr: [])])
        }
        let row = try #require(database.writer.read { db in
            try HistoricalRecordRow.fetchOne(db, sql: "SELECT * FROM historical_record")
        })
        #expect(row.version == 24)
        #expect(row.bpm == nil) // no reading stored as NULL
        #expect(row.contact == false)
        #expect(row.rrMsJSON == "[]")
        #expect(row.rrMs == [])
        #expect(row.ppgGreen == 15_840)
        #expect(row.spo2Red == 8_000)
        #expect(row.spo2Ir == 12_000)
        #expect(row.skinTempRaw == 3_900)
        #expect(row.respRateRaw == 660)
        #expect(row.signalQuality == 240)
        #expect(row.gravityX == 0.012)
        #expect(row.gravityY == -0.031)
        #expect(row.gravityZ == 0.999)
        #expect(row.gravity2X == 0.002)
        #expect(row.gravity2Y == -0.004)
        #expect(row.gravity2Z == 1.005)
        #expect(row.ambientDrive == 7)
        #expect(row.ledDrive1 == 1_204)
        #expect(row.ledDrive2 == 1_310)
    }

    @Test func rrJSONDecodesTheStoredIntervals() throws {
        let database = try seededDatabase()
        _ = try database.writer.write { db in
            try db.insertHistoricalSamples([sample(nightStartMs, rr: [995, 1_004.5])])
        }
        let row = try #require(database.writer.read { db in
            try HistoricalRecordRow.fetchOne(db, sql: "SELECT * FROM historical_record")
        })
        #expect(row.rrMs == [995, 1_004.5])
        #expect(row.sleepRecord.rrMs == [995, 1_004.5])
    }

    @Test func derivesAndStoresOneSessionPerNight() throws {
        let database = try seededDatabase()
        try insertNight(database)
        let bandID = try storedBandID(of: database)
        let from = nightStartMs - 3_600_000
        let to = nightStartMs + 9 * 3_600_000

        let written = try database.writer.write { db in
            try db.deriveSleepSessions(from: from, to: to, bandID: bandID, in: Self.utc, computedAtMs: testNowMs)
        }
        #expect(written == 1)

        let sessions = try database.writer.read { db in
            try db.sleepSessionRows(bandID: bandID, from: from, to: to)
        }
        #expect(sessions.count == 1)
        let session = sessions[0]
        #expect(session.startMs == nightStartMs)
        #expect(session.endMs == nightStartMs + (8 * 60 * 60 - 120) * 1000)
        #expect(session.durationS == 8 * 60 * 60 - 120)
        #expect(session.restingHr == 55)
        #expect(session.contactFraction == 1)
        #expect(session.qualityValue == .good)
        #expect(session.recordCount == 240)
        #expect(session.respRateRaw == 660)
        // Skin temperature is the settled mean of frame 76 (`led_drive1`), not frame 72.
        #expect(session.skinTemperature == 1_204)
        #expect(session.algoVersion == SleepDeriver.algoVersion)
        #expect(session.computedAt == testNowMs)
    }

    @Test func rederivingReplacesTheSessionInsteadOfDuplicating() throws {
        let database = try seededDatabase()
        try insertNight(database)
        let bandID = try storedBandID(of: database)
        let from = nightStartMs - 3_600_000
        let to = nightStartMs + 9 * 3_600_000

        _ = try database.writer.write { db in
            try db.deriveSleepSessions(from: from, to: to, bandID: bandID, in: Self.utc, computedAtMs: testNowMs)
        }
        let recomputedAt = testNowMs + 60_000
        _ = try database.writer.write { db in
            try db.deriveSleepSessions(from: from, to: to, bandID: bandID, in: Self.utc, computedAtMs: recomputedAt)
        }

        let sessions = try database.writer.read { db in
            try db.sleepSessionRows(bandID: bandID, from: from, to: to)
        }
        #expect(sessions.count == 1)
        #expect(sessions[0].computedAt == recomputedAt)
    }

    @Test func sessionsStayPerBand() throws {
        let database = try seededDatabase()
        try insertNight(database)
        let firstBand = try storedBandID(of: database)

        // A second band's records land in the same window.
        let otherPeripheral = UUID()
        let otherSamples = nightSamples().map { sample in
            Database.HistoricalSample(
                peripheralUUID: otherPeripheral, tsMs: sample.tsMs, version: 24, bpm: 60, contact: true, rrMs: [],
                gravityX: 0.012, gravityY: -0.031, gravityZ: 0.999
            )
        }
        _ = try database.writer.write { db in
            try db.insertHistoricalSamples(otherSamples)
        }
        let secondBand = try #require(database.writer.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM band WHERE peripheral_uuid = ?", arguments: [otherPeripheral.uuidString])
        })

        _ = try database.writer.write { db in
            try db.deriveSleepSessions(from: nightStartMs - 3_600_000, to: nightStartMs + 9 * 3_600_000, bandID: secondBand, in: Self.utc, computedAtMs: testNowMs)
        }
        let secondBandSessions = try database.writer.read { db in
            try db.sleepSessionRows(bandID: secondBand, from: nightStartMs - 3_600_000, to: nightStartMs + 9 * 3_600_000)
        }
        let firstBandSessions = try database.writer.read { db in
            try db.sleepSessionRows(bandID: firstBand, from: nightStartMs - 3_600_000, to: nightStartMs + 9 * 3_600_000)
        }
        #expect(secondBandSessions.count == 1)
        #expect(secondBandSessions[0].restingHr == 60) // derived from the second band's rows only
        #expect(firstBandSessions.isEmpty) // deriving one band never writes the other's session
    }

    @Test func staleSessionsInTheRangeAreReplacedWithTheirHypnograms() throws {
        let database = try seededDatabase()
        try insertNight(database)
        let bandID = try storedBandID(of: database)
        let from = nightStartMs - 3_600_000
        let to = nightStartMs + 9 * 3_600_000
        // A version-1 "night": the whole worn evening, keyed an hour before the real night.
        let staleStart = nightStartMs - 2_400_000
        try database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO sleep_session (band_id, start_ms, end_ms, duration_s, contact_fraction, quality,
                  record_count, algo_version, computed_at)
                VALUES (?, ?, ?, ?, 0.95, 'good', 26000, 1, ?)
                """, arguments: [bandID, staleStart, nightStartMs + 20 * 3_600_000, 20 * 3600 + 2400, testNowMs])
            try db.replaceSleepStageSegments(
                [StageSegment(startUnix: staleStart / 1000, endUnix: staleStart / 1000 + 600, stage: .light)],
                bandID: bandID, sessionStartMs: staleStart, computedAtMs: testNowMs
            )
            try db.deriveSleepSessions(from: from, to: to, bandID: bandID, in: Self.utc, computedAtMs: testNowMs)
        }

        let (sessions, staleSegments) = try database.writer.read { db in
            (
                try db.sleepSessionRows(bandID: bandID, from: from, to: to),
                try db.sleepStageSegmentRows(bandID: bandID, sessionStartMs: staleStart)
            )
        }
        #expect(sessions.map(\.startMs) == [nightStartMs])
        #expect(staleSegments.isEmpty)
    }

    @Test func aRangeWithoutRecordsWritesNothing() throws {
        let database = try seededDatabase()
        try insertNight(database)
        let bandID = try storedBandID(of: database)

        let written = try database.writer.write { db in
            try db.deriveSleepSessions(from: 0, to: 1000, bandID: bandID, in: Self.utc, computedAtMs: testNowMs)
        }
        #expect(written == 0)
    }
}
