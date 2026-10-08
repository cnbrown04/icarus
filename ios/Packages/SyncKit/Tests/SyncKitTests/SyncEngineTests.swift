import Foundation
import GRDB
import Store
import Testing
@testable import SyncKit

struct SyncEngineTests {
    private func cursor(_ database: AppDatabase) throws -> Int64 {
        try acknowledgedCursor(database, .hrSample)
    }

    private func hrRowsInBatch(_ request: HTTPRequest) throws -> Int {
        let body = try jsonObject(request.body)
        return ((body["hr"] as? [String: Any])?["ts_ms"] as? [Int])?.count ?? 0
    }

    @Test func cursorAdvancesOnlyOnSuccess() async throws {
        let database = try databaseWithReadings(5)
        let transport = ScriptedTransport()
        await transport.queueBatch(.response(problemResponse(500, slug: "internal", detail: "boom")))
        let engine = makeEngine(database: database, outbox: try pairedOutbox(), transport: transport)

        let first = await engine.run()
        #expect(first == .retry(at: testNow.addingTimeInterval(5)))
        #expect(try cursor(database) == 0)
        #expect(try batchLogStatuses(database) == ["pending"])

        let second = await engine.run()
        #expect(second == .synced)
        #expect(try cursor(database) == 5)
        #expect(try batchLogStatuses(database) == ["acked"])
    }

    @Test func pendingBatchIsSentAgainWithTheSameIdempotencyKey() async throws {
        let database = try databaseWithReadings(2)
        let transport = ScriptedTransport()
        await transport.queueBatch(.failure)
        let engine = makeEngine(database: database, outbox: try pairedOutbox(), transport: transport)

        _ = await engine.run()
        _ = await engine.run()

        let uploads = await transport.batchRequests()
        #expect(uploads.count == 2)
        #expect(uploads[0].headers["Idempotency-Key"] == uploads[1].headers["Idempotency-Key"])
        #expect(uploads[0].headers["Idempotency-Key"] != nil)
        #expect(uploads[0].body == uploads[1].body)
    }

    @Test func noContentEncodingHeaderOnLinux() async throws {
        let database = try databaseWithReadings(1)
        let transport = ScriptedTransport()
        let engine = makeEngine(database: database, outbox: try pairedOutbox(), transport: transport)
        _ = await engine.run()
        let upload = try #require(await transport.batchRequests().first)
        #if canImport(Darwin)
        #expect(upload.headers["Content-Encoding"] == "gzip")
        #else
        #expect(upload.headers["Content-Encoding"] == nil)
        #endif
        #expect(upload.headers["Content-Type"] == "application/json")
        #expect(upload.headers["Authorization"] == "Bearer device-token")
    }

    @Test func duplicateReceiptIsSuccess() async throws {
        let database = try databaseWithReadings(4)
        let transport = ScriptedTransport()
        await transport.queueBatch(.response(HTTPResponse(
            status: 200,
            body: Data(#"{"batch_id":"x","duplicate":true,"server_time":"2026-10-07T14:30:00Z","counts":{}}"#.utf8)
        )))
        let engine = makeEngine(database: database, outbox: try pairedOutbox(), transport: transport)
        #expect(await engine.run() == .synced)
        #expect(try cursor(database) == 4)
        #expect(try batchLogStatuses(database) == ["acked"])
    }

    @Test func conflictIsQuarantinedAndLaterRowsGoOutInNewBatches() async throws {
        let database = try databaseWithReadings(3)
        let transport = ScriptedTransport()
        await transport.queueBatch(.response(problemResponse(409, slug: "conflict", detail: "Batch id reused")))
        let outbox = try pairedOutbox()
        let engine = makeEngine(database: database, outbox: outbox, transport: transport)

        #expect(await engine.run() == .synced)
        #expect(try cursor(database) == 0)
        #expect(try batchLogStatuses(database) == ["rejected"])
        #expect(outbox.loadState().quarantine.count == 1)
        #expect(await engine.status().quarantinedBatches == 1)

        // Two new rows arrive after the quarantined batch. Only they are sent, and the cursor stays at the start.
        try dbWrite(database) { db in
            try db.insertReadings([
                Database.Reading(peripheralUUID: testBandPeripheral, tsMs: 50_000, bpm: 70, contact: nil, rr: []),
                Database.Reading(peripheralUUID: testBandPeripheral, tsMs: 51_000, bpm: 71, contact: nil, rr: []),
            ])
        }
        #expect(await engine.run() == .synced)
        let uploads = await transport.batchRequests()
        #expect(uploads.count == 2)
        #expect(try hrRowsInBatch(uploads[1]) == 2)
        #expect(try cursor(database) == 0)
        #expect(try batchLogStatuses(database) == ["rejected", "acked"])
    }

    @Test func validationErrorQuarantinesWithoutRetrying() async throws {
        let database = try databaseWithReadings(2)
        let transport = ScriptedTransport()
        await transport.queueBatch(.response(problemResponse(422, slug: "validation", detail: "bpm out of range")))
        let engine = makeEngine(database: database, outbox: try pairedOutbox(), transport: transport)
        #expect(await engine.run() == .synced)
        #expect(await transport.batchRequests().count == 1)
        let rejected = try dbRead(database) { try $0.syncBatches(status: "rejected", limit: 10) }
        #expect(rejected.first?.httpStatus == 422)
        #expect(rejected.first?.error == "bpm out of range")
    }

    @Test func unauthorizedNeedsRepairAndStopsCalling() async throws {
        let database = try databaseWithReadings(2)
        let transport = ScriptedTransport()
        await transport.queueBatch(.response(problemResponse(401, slug: "unauthorized", detail: "Token revoked")))
        let outbox = try pairedOutbox()
        let engine = makeEngine(database: database, outbox: outbox, transport: transport)

        #expect(await engine.run() == .needsRepair)
        #expect(await engine.status().phase == SyncPhase.needsRepair)
        #expect(try cursor(database) == 0)
        #expect(try batchLogStatuses(database) == ["pending"])

        #expect(await engine.run() == .needsRepair)
        #expect(await transport.requests.count == 1)
    }

    @Test func retryAfterSetsTheNextAttempt() async throws {
        let database = try databaseWithReadings(1)
        let transport = ScriptedTransport()
        await transport.queueBatch(.response(problemResponse(429, slug: "rate-limited", detail: "Slow", headers: ["Retry-After": "30"])))
        let engine = makeEngine(database: database, outbox: try pairedOutbox(), transport: transport)

        #expect(await engine.run() == .retry(at: testNow.addingTimeInterval(30)))
        #expect(await engine.status().phase == .retrying(at: testNow.addingTimeInterval(30)))
    }

    @Test func networkFailureBacksOffFromFiveSeconds() async throws {
        let database = try databaseWithReadings(1)
        let transport = ScriptedTransport()
        await transport.queueBatch(.failure)
        let engine = makeEngine(database: database, outbox: try pairedOutbox(), transport: transport)
        #expect(await engine.run() == .retry(at: testNow.addingTimeInterval(5)))
    }

    @Test func unpairedAndTokenlessEnginesDoNotCallTheNetwork() async throws {
        let database = try databaseWithReadings(1)
        let transport = ScriptedTransport()
        let unpaired = SyncEngine(database: database, outbox: temporaryOutbox(), tokens: InMemoryTokenStore(), transport: transport, clock: testClock)
        #expect(await unpaired.run() == .notPaired)
        #expect(await unpaired.status().phase == SyncPhase.notPaired)

        let tokenless = makeEngine(database: database, outbox: try pairedOutbox(), transport: transport, token: nil)
        #expect(await tokenless.run() == .notPaired)
        #expect(await transport.requests.isEmpty)
    }

    @Test func configAppliesAlarmsIncludingTombstones() async throws {
        let database = try AppDatabase.inMemory()
        let transport = ScriptedTransport()
        await transport.setConfig(HTTPResponse(status: 200, body: Data(#"""
        {"alarms":[
          {"id":"a1","kind":"scheduled","label":"Wake up","schedule":{"time":"06:30","weekdays":[1,2,3,4,5]},
           "rhythm":"single","channels":["phone","band"],"enabled":true,"version":3,
           "updated_at":"2026-10-07T14:00:00Z","deleted_at":null},
          {"id":"a2","kind":"webhook","label":"Front door","schedule":null,
           "rhythm":[{"type":"buzz","preset":2,"loops":1},{"type":"pause","ms":300}],"channels":["phone"],
           "enabled":false,"version":4,"updated_at":"2026-10-07T14:05:00Z","deleted_at":"2026-10-07T14:06:00Z"}
        ],"webhook_endpoints":[{"id":"h1","slug":"front-door"}],
        "profile":null,"max_version":4,"server_time":"2026-10-07T14:30:00Z"}
        """#.utf8)))
        let outbox = try pairedOutbox()
        let engine = makeEngine(database: database, outbox: outbox, transport: transport)

        #expect(await engine.run() == .synced)

        let alarms = try dbRead(database) { db in
            try Row.fetchAll(db, sql: "SELECT id, enabled, deleted_at, rhythm, channels, version FROM alarm ORDER BY id")
        }
        #expect(alarms.count == 2)
        #expect(alarms[0]["rhythm"] as String? == "\"single\"")
        #expect(alarms[0]["deleted_at"] as Int64? == nil)
        #expect(alarms[1]["deleted_at"] as Int64? != nil)
        #expect(alarms[1]["enabled"] as Int64? == 0)
        #expect(outbox.loadState().alarmsVersion == 4)
        let hooks = try #require(try? Data(contentsOf: outbox.directory.appendingPathComponent("hooks.json")))
        #expect(String(decoding: hooks, as: UTF8.self).contains("front-door"))

        // The next pull asks only for what changed since version 4.
        await transport.setConfig(HTTPResponse(status: 200, body: Data(#"{"alarms":[],"webhook_endpoints":[],"profile":null,"max_version":4,"server_time":"2026-10-07T14:30:00Z"}"#.utf8)))
        _ = await engine.run()
        let since = try #require(await transport.configRequests().last?.url.query)
        #expect(since == "since=4")
        let hooksAfter = try Data(contentsOf: outbox.directory.appendingPathComponent("hooks.json"))
        #expect(String(decoding: hooksAfter, as: UTF8.self) == "[]")
    }

    @Test func emptyServerProfileDoesNotOverwriteLocalProfile() async throws {
        let database = try AppDatabase.inMemory()
        try dbWrite(database) { db in
            try db.saveProfile(ProfileRow(formulaSex: "female", birthYear: 1990, heightCm: 165, weightKg: 60), atMs: 1)
        }
        let transport = ScriptedTransport()
        let engine = makeEngine(database: database, outbox: try pairedOutbox(), transport: transport)
        _ = await engine.run()
        let profile = try #require(try dbRead(database) { try $0.profile() })
        #expect(profile.formulaSex == "female")
    }

    @Test func serverProfileWithValuesAppliesOnceForANewerVersion() async throws {
        let database = try AppDatabase.inMemory()
        let transport = ScriptedTransport()
        let profileJSON = #"{"alarms":[],"webhook_endpoints":[],"profile":{"formula_sex":"male","birth_year":1985,"height_cm":180,"weight_kg":78.5,"hr_max":null,"tz":"America/New_York","version":2},"max_version":0,"server_time":"2026-10-07T14:30:00Z"}"#
        await transport.setConfig(HTTPResponse(status: 200, body: Data(profileJSON.utf8)))
        let outbox = try pairedOutbox()
        let engine = makeEngine(database: database, outbox: outbox, transport: transport)
        _ = await engine.run()

        let profile = try #require(try dbRead(database) { try $0.profile() })
        #expect(profile.formulaSex == "male")
        #expect(profile.weightKg == 78.5)
        #expect(profile.tz == "America/New_York")
        #expect(profile.version == 2)
        #expect(outbox.loadState().profileVersion == 2)
    }

    @Test func skewWarningAppearsPastTwoMinutes() async throws {
        let database = try AppDatabase.inMemory()
        let transport = ScriptedTransport()
        await transport.setConfig(HTTPResponse(status: 200, body: Data(#"{"alarms":[],"webhook_endpoints":[],"profile":null,"max_version":0,"server_time":"2026-10-07T14:33:00Z"}"#.utf8)))
        let engine = makeEngine(database: database, outbox: try pairedOutbox(), transport: transport)
        _ = await engine.run()
        #expect(await engine.status().clockSkewWarning)
    }

    @Test func successfulRunRecordsLastSuccess() async throws {
        let database = try databaseWithReadings(2)
        let engine = makeEngine(database: database, outbox: try pairedOutbox(), transport: ScriptedTransport())
        #expect(await engine.status().lastSuccessAt == nil)
        _ = await engine.run()
        #expect(await engine.status().lastSuccessAt == testNow)
        #expect(await engine.status().phase == SyncPhase.idle)
    }

    @Test func settledBackgroundUploadAdvancesTheCursor() async throws {
        let database = try databaseWithReadings(3)
        let outbox = try pairedOutbox()
        let batch = try dbWrite(database) { db in
            try BatchBuilder().build(db, deviceID: testDeviceID, from: [:], batchID: UUIDv7.make(unixMs: 1), nowMs: 1)
        }
        let built = try #require(batch)
        try outbox.writeBatch(built)
        try dbWrite(database) { db in
            try db.recordSyncBatch(id: built.id, createdAtMs: 1, rows: built.rowCount, status: "sent")
        }
        try outbox.writeResult(BackgroundResult(status: 200, message: nil, retryAfter: nil), id: built.id)

        let engine = makeEngine(database: database, outbox: outbox, transport: ScriptedTransport())
        #expect(await engine.run() == .synced)
        #expect(try cursor(database) == 3)
        #expect(try batchLogStatuses(database) == ["acked"])
    }

    @Test func sentBatchWithoutAResultIsSentAgain() async throws {
        let database = try databaseWithReadings(2)
        let outbox = try pairedOutbox()
        let built = try #require(try dbWrite(database) { db in
            try BatchBuilder().build(db, deviceID: testDeviceID, from: [:], batchID: UUIDv7.make(unixMs: 1), nowMs: 1)
        })
        try outbox.writeBatch(built)
        try dbWrite(database) { db in
            try db.recordSyncBatch(id: built.id, createdAtMs: 1, rows: built.rowCount, status: "sent")
        }
        let transport = ScriptedTransport()
        let engine = makeEngine(database: database, outbox: outbox, transport: transport)
        #expect(await engine.run() == .synced)
        let upload = try #require(await transport.batchRequests().first)
        #expect(upload.headers["Idempotency-Key"] == built.id)
        #expect(try cursor(database) == 2)
    }

    @Test func snapshotCountsRowsPastTheCursors() async throws {
        let database = try databaseWithReadings(5)
        try dbWrite(database) { db in
            try db.advanceSyncCursor(.hrSample, to: 2, succeededAtMs: 1)
        }
        let snapshot = try dbRead(database) { try SyncSnapshot.load($0) }
        #expect(snapshot.pendingRows == 3)
    }

    @Test func fixtureSeedsAPairedDeviceWithoutNetwork() async throws {
        let database = try AppDatabase.inMemory()
        let outbox = temporaryOutbox()
        let tokens = InMemoryTokenStore()
        let engine = try SyncFixture.seedPaired(database: database, outbox: outbox, tokens: tokens, now: testNow)
        #expect(await engine.status().phase == SyncPhase.idle)
        #expect(await engine.status().quarantinedBatches == 1)
        #expect(try cursor(database) == 40)
        let snapshot = try dbRead(database) { try SyncSnapshot.load($0) }
        #expect(snapshot.pendingRows == 20)
        #expect(try dbRead(database) { try $0.syncBatches(limit: 50) }.count == 5)
    }
}
