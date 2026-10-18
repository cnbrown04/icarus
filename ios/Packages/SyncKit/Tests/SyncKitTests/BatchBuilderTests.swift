import Foundation
import GRDB
import Store
import Testing
@testable import SyncKit

struct BatchBuilderTests {
    private func build(_ database: AppDatabase, from: StreamPositions = [:], builder: BatchBuilder = BatchBuilder()) throws -> PreparedBatch? {
        try dbWrite(database) { db in
            try builder.build(db, deviceID: testDeviceID, from: from, batchID: UUIDv7.make(unixMs: 1_791_383_400_000), nowMs: 1_791_383_400_000)
        }
    }

    private func advance(_ database: AppDatabase, to batch: PreparedBatch) throws {
        try dbWrite(database) { db in
            for stream in SyncStream.allCases {
                let end = batch.to[stream] ?? 0
                if end > (batch.from[stream] ?? 0) {
                    try db.advanceSyncCursor(stream, to: end, succeededAtMs: 1)
                }
            }
        }
    }

    @Test func buildsColumnarBodyForOneBand() throws {
        let database = try databaseWithReadings(3)
        try dbWrite(database) { db in
            try db.insertReadings([
                Database.Reading(peripheralUUID: testBandPeripheral, tsMs: 9_000, bpm: 62, contact: nil, rr: [
                    Database.Interval(seq: 0, rrMs: 812, accepted: true),
                    Database.Interval(seq: 1, rrMs: 2400, accepted: false),
                ]),
            ])
        }
        let batch = try #require(try build(database))
        let body = try jsonObject(batch.body)
        #expect(body["schema"] as? Int == 1)
        #expect(body["batch_id"] as? String == batch.id)
        #expect(batch.id.count == 36 && batch.id == batch.id.lowercased())
        let bandID = try dbRead(database) { try String.fetchOne($0, sql: "SELECT id FROM band") }
        let bands = try #require(body["bands"] as? [[String: Any]])
        #expect(bands.first?["id"] as? String == bandID)
        let hr = try #require(body["hr"] as? [String: Any])
        #expect((hr["ts_ms"] as? [Int]).map(\.count) == 4)
        #expect((hr["bpm"] as? [Int])?.last == 62)
        let rr = try #require(body["rr"] as? [String: Any])
        #expect((rr["rr_ms"] as? [Double]) == [812, 2400])
        #expect((rr["accepted"] as? [Bool]) == [true, false])
        let cursors = try #require(body["cursors"] as? [String: Int])
        #expect(cursors["hr_sample"] == 4)
        #expect(cursors["rr_interval"] == 2)
        #expect(batch.rowCount == 6)
    }

    @Test func splitsABacklogIntoBatchesOfTheRowLimit() throws {
        let database = try databaseWithReadings(7)
        let builder = BatchBuilder(rowLimit: 3)
        var sizes: [Int] = []
        while let batch = try build(database, from: try readFrom(database), builder: builder) {
            sizes.append(batch.rowCount)
            try advance(database, to: batch)
        }
        #expect(sizes == [3, 3, 1])
        #expect(try acknowledgedCursor(database, .hrSample) == 7)
    }

    @Test func returnsNothingWhenNoStreamHasRowsPastTheStart() throws {
        let database = try AppDatabase.inMemory()
        #expect(try build(database) == nil)
    }

    @Test func takesOnlyOneBandPerBatchAsAPrefix() throws {
        let database = try AppDatabase.inMemory()
        let other = UUID(uuidString: "6C1F3A10-2B7D-4E0A-9C11-0000000000B2")!
        try dbWrite(database) { db in
            try db.insertReadings([
                Database.Reading(peripheralUUID: testBandPeripheral, tsMs: 1_000, bpm: 60, contact: nil, rr: []),
                Database.Reading(peripheralUUID: other, tsMs: 2_000, bpm: 61, contact: nil, rr: []),
                Database.Reading(peripheralUUID: testBandPeripheral, tsMs: 3_000, bpm: 62, contact: nil, rr: []),
            ])
        }
        let first = try #require(try build(database))
        #expect(first.rowCount == 1)
        #expect(first.to[.hrSample] == 1)
        try advance(database, to: first)
        let second = try #require(try build(database, from: try readFrom(database)))
        let body = try jsonObject(second.body)
        #expect((body["hr"] as? [String: Any]).flatMap { $0["bpm"] as? [Int] } == [61])
        #expect(second.rowCount == 1)
    }

    @Test func minuteRowsGoAsNullsWhenTheValueIsMissing() throws {
        let database = try AppDatabase.inMemory()
        try dbWrite(database) { db in
            try minuteRow(minuteMs: 60_000, hrAvg: nil, syncRev: 5).insert(db)
        }
        let batch = try #require(try build(database))
        let body = try jsonObject(batch.body)
        #expect(body["hr"] is NSNull)
        #expect(body["rr"] is NSNull)
        let minutes = try #require(body["minute_metrics"] as? [[String: Any]])
        #expect(minutes.count == 1)
        #expect(minutes[0]["hr_avg"] is NSNull)
        #expect(minutes[0]["sync_rev"] as? Int == 5)
        #expect(batch.to[.minuteMetric] == 5)
        #expect(batch.to[.hrSample] == 0)
    }

    @Test func includesEventsAndAlarmDeliveries() throws {
        let database = try AppDatabase.inMemory()
        try dbWrite(database) { db in
            let bandID = try db.upsertBand(peripheralUUID: testBandPeripheral, name: "Band", seenAtMs: 1)
            try db.insertBandEvent(bandID: bandID, tsMs: 5, kind: "wrist_off", payload: #"{"x":1}"#)
            try db.execute(sql: """
            INSERT INTO alarm_delivery (id, alarm_id, dispatch_id, ts_ms, channel, status, detail)
            VALUES ('d1', NULL, NULL, 10, 'phone', 'shown', NULL)
            """)
        }
        let batch = try #require(try build(database))
        let body = try jsonObject(batch.body)
        let events = try #require(body["events"] as? [[String: Any]])
        #expect(events.first?["kind"] as? String == "wrist_off")
        #expect((events.first?["payload"] as? [String: Any])?["x"] as? Int == 1)
        let deliveries = try #require(body["alarm_deliveries"] as? [[String: Any]])
        #expect(deliveries.first?["id"] as? String == "d1")
        #expect(deliveries.first?["alarm_id"] is NSNull)
        #expect(deliveries.first?["status"] as? String == "shown")
        #expect(batch.to[.alarmDelivery] == 1)
    }

    @Test func shrinksBatchesThatAreOverTheByteLimit() throws {
        let database = try databaseWithReadings(50)
        let batch = try #require(try build(database, builder: BatchBuilder(byteLimit: 700)))
        #expect(batch.rowCount < 50)
        #expect(batch.body.count <= 700)
    }

    private func readFrom(_ database: AppDatabase) throws -> StreamPositions {
        try dbRead(database) { db in
            var positions: StreamPositions = [:]
            for stream in SyncStream.allCases {
                positions[stream] = try db.syncCursor(stream)
            }
            return positions
        }
    }

    private func minuteRow(minuteMs: Int64, hrAvg: Double?, syncRev: Int64) -> MinuteMetricRow {
        MinuteMetricRow(
            minuteMs: minuteMs,
            hrAvg: hrAvg,
            hrMin: nil,
            hrMax: nil,
            hrN: 0,
            rmssdMs: nil,
            sdnnMs: nil,
            baevskySqrt: nil,
            stress: nil,
            stressState: "insufficient",
            kcal: 1,
            activeKcal: 0,
            kcalEstimated: true,
            algoVersion: 1,
            computedAt: 0,
            syncRev: syncRev
        )
    }
}
