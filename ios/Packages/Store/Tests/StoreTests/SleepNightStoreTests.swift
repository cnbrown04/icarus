import Foundation
import GRDB
import Metrics
import Testing
@testable import Store

// The daily numbers (resting HR, night RMSSD) are anchored to the detected main sleep that ended on the
// day, and naps never anchor a night (CONTEXT lesson 7). Naps are stored with `is_nap` (schema v5).
@Suite("Night anchoring and nap flag")
struct SleepNightStoreTests {
    /// The wake day. Its night is the sleep 23:00 the evening before to 07:00 on this day.
    private let day = LocalDay(year: 2026, month: 10, day: 8)

    private func localMs(_ day: LocalDay, _ hour: Int, _ minute: Int = 0) -> Int64 {
        LocalTime.localTime(day, hour: hour, in: chicago) + Int64(minute) * LocalTime.msPerMinute
    }

    /// A derived session over `[start, end]` built the way the app builds one: two on-wrist records at 55 bpm.
    private func session(startMs: Int64, endMs: Int64, isNap: Bool) throws -> SleepSession {
        let records = [
            SleepRecord(unixSeconds: startMs / 1000, bpm: 55, rrMs: [], skinContact: true),
            SleepRecord(unixSeconds: endMs / 1000, bpm: 55, rrMs: [], skinContact: true),
        ]
        return try #require(SleepDeriver.summarize(
            records,
            startUnix: startMs / 1000,
            endUnix: endMs / 1000,
            isNap: isNap
        ))
    }

    /// Minute rows for the evening before `day` and for the early morning of `day`.
    /// 23:30-23:34 is at 48 bpm with a 30 ms window RMSSD at 23:30. 03:00-03:04 is at 55 bpm with 60 ms at 03:00.
    /// Only the detected main sleep (23:00 to 07:00) reaches the 23:30 rows, so only it can change the answer.
    private func seedNight(_ database: AppDatabase) throws {
        let eveningDay = LocalTime.adding(days: -1, to: day)
        var rows: [MinuteMetricRow] = []
        for minute in 30..<35 {
            rows.append(minuteRow(localMs(eveningDay, 23, minute), hr: 48, rmssd: minute == 30 ? 30 : nil))
        }
        for minute in 0..<5 {
            rows.append(minuteRow(localMs(day, 3, minute), hr: 55, rmssd: minute == 0 ? 60 : nil))
        }
        try insertMinuteRows(rows, into: database)
    }

    private func storedBandID(_ database: AppDatabase) throws -> String {
        try #require(database.writer.read { db in try String.fetchOne(db, sql: "SELECT id FROM band") })
    }

    @Test func theDailyNightIsTheMainSleepThatEndedThatDay() throws {
        let database = try seededDatabase()
        try seedNight(database)
        let main = try session(
            startMs: localMs(LocalTime.adding(days: -1, to: day), 23),
            endMs: localMs(day, 7),
            isNap: false
        )
        let band = try storedBandID(database)
        _ = try database.writer.write { db in
            try db.insertSleepSessions([main], bandID: band, computedAtMs: testNowMs)
        }

        let summary = try #require(database.writer.read { try $0.daySummaries([day], in: chicago) }.first)
        // The 23:30 run at 48 bpm is inside the detected sleep, so it sets the night's resting HR.
        #expect(summary.restingHR == 48)
        // Window starts 23:30 (30 ms) and 03:00 (60 ms) are both inside the night: median 45.
        #expect(summary.rmssdNight == 45)
        let rhr = try database.writer.read { try $0.restingHeartRate(night: day, in: chicago) }
        #expect(rhr == 48)
    }

    @Test func aDayWithoutASessionFallsBackToSixAM() throws {
        let database = try seededDatabase()
        try seedNight(database)

        let summary = try #require(database.writer.read { try $0.daySummaries([day], in: chicago) }.first)
        // Only the 03:00 rows are inside 00:00-06:00, so the evening's 48 bpm run does not count.
        #expect(summary.restingHR == 55)
        #expect(summary.rmssdNight == 60)
    }

    @Test func aNapNeverAnchorsTheNight() throws {
        let database = try seededDatabase()
        try seedNight(database)
        let nap = try session(startMs: localMs(day, 1), endMs: localMs(day, 6), isNap: true)
        let band = try storedBandID(database)
        _ = try database.writer.write { db in
            try db.insertSleepSessions([nap], bandID: band, computedAtMs: testNowMs)
        }

        let summary = try #require(database.writer.read { try $0.daySummaries([day], in: chicago) }.first)
        #expect(summary.restingHR == 55)
        #expect(summary.rmssdNight == 60)
    }

    @Test func theNapFlagRoundTripsAndUpdatesOnConflict() throws {
        let database = try seededDatabase()
        let start = localMs(day, 13)
        let band = try storedBandID(database)

        _ = try database.writer.write { db in
            try db.insertSleepSessions([try session(startMs: start, endMs: start + 3_600_000, isNap: true)], bandID: band, computedAtMs: testNowMs)
        }
        let stored = try #require(database.writer.read { db in
            try SleepSessionRow.fetchOne(db, sql: "SELECT * FROM sleep_session")
        })
        #expect(stored.isNap)
        #expect(stored.span == SleepSpan(startMs: start, endMs: start + 3_600_000, isNap: true))

        // The same session re-derived as a main sleep (the upsert path) updates the flag.
        _ = try database.writer.write { db in
            try db.insertSleepSessions([try session(startMs: start, endMs: start + 3_600_000, isNap: false)], bandID: band, computedAtMs: testNowMs)
        }
        let rows = try database.writer.read { db in
            try SleepSessionRow.fetchAll(db, sql: "SELECT * FROM sleep_session")
        }
        #expect(rows.count == 1)
        #expect(rows.first?.isNap == false)
    }
}
