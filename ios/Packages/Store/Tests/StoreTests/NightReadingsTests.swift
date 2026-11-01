import Foundation
import GRDB
import Metrics
import Testing
@testable import Store

// The readings behind a nightly vital: the stored night value is the floor (resting HR) and mean (HRV) of them.
@Suite("Night readings")
struct NightReadingsTests {
    private let day = LocalDay(year: 2026, month: 10, day: 20)

    @Test func readingsReproduceTheStoredNightlyValues() throws {
        let database = try seededDatabase()
        let band = try #require(database.writer.read { db in try String.fetchOne(db, sql: "SELECT id FROM band") })
        let end = LocalTime.localTime(day, hour: 7, in: chicago)
        let start = end - 40 * 60_000

        // 1 Hz records whose heart rate steps every 10 minutes and whose R-R alternates, so every 5-minute window
        // has an RMSSD and the resting floor is one of the bins.
        var records: [SleepRecord] = []
        try database.writer.write { db in
            for second in stride(from: Int64(0), through: (end - start) / 1000, by: 1) {
                let bpm = 52 + Int((second / 600) % 4)
                let rr = second.isMultiple(of: 2) ? 1_000.0 : 1_040 + Double((second / 300) % 3) * 10
                let ts = start + second * 1000
                try db.execute(sql: """
                    INSERT INTO historical_record (band_id, ts_ms, version, bpm, contact, rr_ms) VALUES (?, ?, 24, ?, 1, ?)
                    """, arguments: [band, ts, bpm, "[\(Int(rr))]"])
                records.append(SleepRecord(unixSeconds: ts / 1000, bpm: Double(bpm), rrMs: [rr], skinContact: true))
            }
        }
        let session = try #require(SleepDeriver.summarize(records, startUnix: start / 1000, endUnix: end / 1000))
        try database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO sleep_session (band_id, start_ms, end_ms, duration_s, resting_hr, rmssd_ms,
                  contact_fraction, quality, record_count, is_nap, algo_version, computed_at)
                VALUES (?, ?, ?, ?, ?, ?, 1, 'good', ?, 0, ?, ?)
                """, arguments: [band, start, end, (end - start) / 1000, session.restingHeartRate, session.rmssdMs,
                                 records.count, SleepDeriver.algoVersion, testNowMs])
        }

        let nights = try database.writer.read { try $0.vitalNights(.restingHR, nowMs: end + 1, limit: 10, in: chicago) }
        let night = try #require(nights.first)
        #expect(nights.count == 1)
        #expect(night.day == day)
        #expect(night.value == session.restingHeartRate)

        let resting = try database.writer.read { try $0.nightReadings(.restingHR, night: night) }
        // Eight full 5-minute bins; the ninth holds only the final second and fails the 5-sample gate.
        #expect(resting.count == 8)
        #expect(resting.map(\.value).min() == session.restingHeartRate)

        let hrv = try database.writer.read { try $0.nightReadings(.hrv, night: night) }.map(\.value)
        let mean = hrv.reduce(0, +) / Double(hrv.count)
        #expect(abs(mean - (session.rmssdMs ?? -1)) < 1e-9)
        #expect(try database.writer.read { try $0.nightReadings(.stress, night: night) }.isEmpty)
    }

    @Test func intervalListsParseLikeJSON() {
        #expect(Database.parseIntervals("[812,830,1004]") == [812, 830, 1_004])
        #expect(Database.parseIntervals("[]").isEmpty)
        #expect(Database.parseIntervals("[812.5, 830]") == [812.5, 830])
    }

    /// A derived session stores its readings, and the range read returns them for the day the sleep ended.
    @Test func storedSessionReadingsComeBackOverARange() throws {
        let database = try seededDatabase()
        let band = try #require(database.writer.read { db in try String.fetchOne(db, sql: "SELECT id FROM band") })
        let end = LocalTime.localTime(day, hour: 7, in: chicago) / 1000
        let start = end - 30 * 60
        let records = stride(from: start, through: end, by: 1).map { second in
            SleepRecord(unixSeconds: second, bpm: 55, rrMs: [second.isMultiple(of: 2) ? 1_000 : 1_040], skinContact: true)
        }
        let session = try #require(SleepDeriver.summarize(records, startUnix: start, endUnix: end))
        #expect(!session.readings.hrv.isEmpty)
        try database.writer.write { db in
            try db.insertSleepSessions([session], bandID: band, computedAtMs: testNowMs)
            // Re-writing the session replaces its readings rather than adding to them.
            try db.insertSleepSessions([session], bandID: band, computedAtMs: testNowMs)
        }
        let hrv = try database.writer.read { try $0.vitalReadings(.hrv, from: day, through: day, in: chicago) }
        #expect(hrv.map(\.value) == session.readings.hrv.map(\.value))
        #expect(hrv.map(\.tsMs) == session.readings.hrv.map { $0.unixSeconds * 1000 })
        let none = try database.writer.read {
            try $0.vitalReadings(.hrv, from: LocalTime.adding(days: -3, to: day), through: LocalTime.adding(days: -1, to: day), in: chicago)
        }
        #expect(none.isEmpty)
    }

    /// All-day HRV is computed awake too, and a window that overlaps a main sleep is left to the sleep's readings.
    @Test func awakeReadingsSkipTheMainSleep() throws {
        let database = try seededDatabase()
        let band = try #require(database.writer.read { db in try String.fetchOne(db, sql: "SELECT id FROM band") })
        let wake = LocalTime.localTime(day, hour: 7, in: chicago)
        let start = wake - 30 * 60_000
        let end = wake + 60 * 60_000
        try database.writer.write { db in
            for ts in stride(from: start, to: end, by: 1000) {
                let rr = (ts / 1000).isMultiple(of: 2) ? 1_000 : 1_040
                try db.execute(sql: "INSERT INTO historical_record (band_id, ts_ms, version, bpm, contact, rr_ms) VALUES (?, ?, 24, 60, 1, ?)",
                               arguments: [band, ts, "[\(rr)]"])
            }
            // Asleep until 07:00, awake after.
            try db.execute(sql: """
                INSERT INTO sleep_session (band_id, start_ms, end_ms, duration_s, contact_fraction, quality, record_count,
                  is_nap, algo_version, computed_at) VALUES (?, ?, ?, 1800, 1, 'good', 1800, 0, ?, ?)
                """, arguments: [band, start, wake, SleepDeriver.algoVersion, testNowMs])
            try db.deriveDayReadings(from: start, to: end, bandID: band)
        }
        let all = try database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM day_reading WHERE vital = 'rmssd'") ?? 0
        }
        #expect(all == 18)
        let awake = try database.writer.read { try $0.awakeReadings(.hrv, fromMs: start, toMs: end, in: chicago) }
        #expect(awake.count == 12)
        #expect(awake.allSatisfy { $0.tsMs >= wake && abs($0.value - 40) < 1e-9 })
        #expect(try database.writer.read { try $0.awakeReadings(.restingHR, fromMs: start, toMs: end, in: chicago) }.isEmpty)
    }
}
