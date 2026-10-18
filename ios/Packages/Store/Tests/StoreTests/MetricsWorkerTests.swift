import Foundation
import GRDB
import Metrics
import Testing
@testable import Store

struct MetricsWorkerTests {
    private func storeOneMinuteSamples(into database: AppDatabase, endingAt nowMs: Int64, minutes: Int, bpm: Int) throws {
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

    @Test func doesNothingWithoutACompleteProfile() async throws {
        let database = try AppDatabase.inMemory()
        let worker = MetricsWorker(database: database)
        let result = try await worker.recompute(nowMs: testNowMs)
        #expect(result == MetricsWorker.Result(changedRows: 0, ran: false))
    }

    @Test func computesClosedMinutesFromStoredSamples() async throws {
        let database = try seededDatabase()
        try storeOneMinuteSamples(into: database, endingAt: testNowMs, minutes: 30, bpm: 60)
        let worker = MetricsWorker(database: database)

        let first = try await worker.recompute(nowMs: testNowMs)
        #expect(first.ran)
        #expect(first.changedRows == 30)

        let rows = try await database.writer.read { try $0.minuteMetricRows(from: testNowMs - 10 * 60_000, to: testNowMs) }
        #expect(rows.count == 10)
        #expect(rows.allSatisfy { $0.hrAvg == 60 && $0.hrN == 60 })
        #expect(rows.allSatisfy { $0.kcal > 0 && $0.kcalEstimated == false })
    }

    @Test func secondRunOnTheSameInputsChangesNothing() async throws {
        let database = try seededDatabase()
        try storeOneMinuteSamples(into: database, endingAt: testNowMs, minutes: 30, bpm: 60)
        let worker = MetricsWorker(database: database)
        _ = try await worker.recompute(nowMs: testNowMs)
        let second = try await worker.recompute(nowMs: testNowMs)
        #expect(second.ran)
        #expect(second.changedRows == 0)
    }

    @Test func newSamplesUpdateTheMinutesInTheLookback() async throws {
        let database = try seededDatabase()
        try storeOneMinuteSamples(into: database, endingAt: testNowMs, minutes: 12, bpm: 60)
        let worker = MetricsWorker(database: database)
        _ = try await worker.recompute(nowMs: testNowMs)

        let later = testNowMs + 60_000
        _ = try await database.writer.write { db in
            let readings = (0..<60).map { index in
                Database.Reading(peripheralUUID: testPeripheral, tsMs: testNowMs + Int64(index) * 1000, bpm: 90, contact: true, rr: [])
            }
            try db.insertReadings(readings)
        }
        let result = try await worker.recompute(nowMs: later)
        #expect(result.changedRows >= 1)
        let latest = try await database.writer.read { try $0.minuteMetricRows(from: testNowMs, to: testNowMs + 60_000) }
        #expect(latest.first?.hrAvg == 90)
    }

    @Test func rebuiltWindowsCarryTheStoredRMSSDOnlyOnceEach() {
        let rows = [
            minuteRow(0, hr: 60, rmssd: 45),
            minuteRow(60_000, hr: 62, rmssd: 45),
            minuteRow(300_000, hr: 70, rmssd: nil),
        ]
        let windows = FiveMinuteWindow.rebuilt(from: rows)
        #expect(windows.map(\.startMs) == [0, 300_000])
        #expect(windows[0].valid)
        #expect(windows[0].rmssd == 45)
        #expect(windows[1].valid == false)
    }

    @Test func nightWindowCountsOnlyTheNightBeforeAnyMorning() {
        let evening = testNowMs
        let day = NightWindow.latestCompleted(nowMs: evening, in: chicago)
        #expect(day == LocalDay(year: 2026, month: 10, day: 7))
    }
}
