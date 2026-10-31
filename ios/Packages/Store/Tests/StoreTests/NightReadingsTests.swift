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
}
