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
            signalQuality: 240
        )
    }

    /// 240 two-minute records from 23:00 to 05:58 UTC, so the gaps (120 s) stay far below the
    /// 30-minute split threshold.
    private func nightSamples() -> [Database.HistoricalSample] {
        stride(from: 0, to: 8 * 60 * 60, by: 120).map { offset in
            sample(nightStart + offset)
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
            try db.insertHistoricalSamples([sample(nightStart)])
        }
        #expect(inserted == 1)

        let replayed = try database.writer.write { db in
            try db.insertHistoricalSamples([sample(nightStart), sample(nightStart + 120_000)])
        }
        #expect(replayed == 1) // the first sample deduped, the new one inserted

        let rows = try database.writer.read { db in
            try HistoricalRecordRow.fetchAll(db, sql: "SELECT * FROM historical_record ORDER BY ts_ms")
        }
        #expect(rows.count == 2)
        #expect(rows[0].tsMs == nightStart)
        #expect(rows[1].tsMs == nightStart + 120_000)
    }

    @Test func sampleFieldsRoundTrip() throws {
        let database = try seededDatabase()
        _ = try database.writer.write { db in
            try db.insertHistoricalSamples([sample(nightStart, bpm: nil, contact: false, rr: [])])
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
    }

    @Test func rrJSONDecodesTheStoredIntervals() throws {
        let database = try seededDatabase()
        _ = try database.writer.write { db in
            try db.insertHistoricalSamples([sample(nightStart, rr: [995, 1_004.5])])
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
        let from = nightStart - 3_600_000
        let to = nightStart + 9 * 3_600_000

        let written = try database.writer.write { db in
            try db.deriveSleepSessions(from: from, to: to, bandID: bandID, in: Self.utc, computedAtMs: testNowMs)
        }
        #expect(written == 1)

        let sessions = try database.writer.read { db in
            try db.sleepSessionRows(bandID: bandID, from: from, to: to)
        }
        #expect(sessions.count == 1)
        let session = sessions[0]
        #expect(session.startMs == nightStart)
        #expect(session.endMs == nightStart + 8 * 60 * 60 - 120_000)
        #expect(session.durationS == 8 * 60 * 60 - 120)
        #expect(session.restingHr == 55)
        #expect(session.contactFraction == 1)
        #expect(session.qualityValue == .good)
        #expect(session.recordCount == 240)
        #expect(session.respRateRaw == 660)
        #expect(session.skinTempRaw == 3_900)
        #expect(session.algoVersion == SleepDeriver.algoVersion)
        #expect(session.computedAt == testNowMs)
    }

    @Test func rederivingReplacesTheSessionInsteadOfDuplicating() throws {
        let database = try seededDatabase()
        try insertNight(database)
        let bandID = try storedBandID(of: database)
        let from = nightStart - 3_600_000
        let to = nightStart + 9 * 3_600_000

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
                peripheralUUID: otherPeripheral, tsMs: sample.tsMs, version: 24, bpm: 60, contact: true, rrMs: []
            )
        }
        _ = try database.writer.write { db in
            try db.insertHistoricalSamples(otherSamples)
        }
        let secondBand = try #require(database.writer.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM band WHERE peripheral_uuid = ?", arguments: [otherPeripheral.uuidString])
        })

        _ = try database.writer.write { db in
            try db.deriveSleepSessions(from: nightStart - 3_600_000, to: nightStart + 9 * 3_600_000, bandID: secondBand, in: Self.utc, computedAtMs: testNowMs)
        }
        let secondBandSessions = try database.writer.read { db in
            try db.sleepSessionRows(bandID: secondBand, from: nightStart - 3_600_000, to: nightStart + 9 * 3_600_000)
        }
        let firstBandSessions = try database.writer.read { db in
            try db.sleepSessionRows(bandID: firstBand, from: nightStart - 3_600_000, to: nightStart + 9 * 3_600_000)
        }
        #expect(secondBandSessions.count == 1)
        #expect(secondBandSessions[0].restingHr == 60) // derived from the second band's rows only
        #expect(firstBandSessions.isEmpty) // deriving one band never writes the other's session
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
