import Foundation
import Store
import Testing
@testable import SyncKit

struct AlarmPushTests {
    static let alarmID = "0192f6c1-7a3e-7c4d-9b1e-0000000000a1"

    static func localAlarm(version: Int64, deleted: Bool = false) -> AlarmRow {
        AlarmRow(
            id: alarmID,
            label: "Wake up",
            schedule: #"{"time":"06:30","weekdays":[1,2,3,4,5]}"#,
            rhythm: #""double""#,
            channels: #"["phone","band"]"#,
            enabled: true,
            version: version,
            deletedAt: deleted ? 1_000 : nil,
            dirty: true
        )
    }

    static func serverAlarm(label: String, version: Int64) -> HTTPResponse {
        HTTPResponse(status: 200, body: Data("""
        {"id":"\(alarmID)","kind":"scheduled","label":"\(label)","schedule":{"time":"06:30","weekdays":[1,2,3,4,5]},\
        "rhythm":"double","channels":["phone","band"],"enabled":true,"version":\(version),\
        "updated_at":"2026-10-07T14:30:00Z","deleted_at":null}
        """.utf8))
    }

    static func setup(_ row: AlarmRow) throws -> (AppDatabase, Outbox) {
        let database = try AppDatabase.inMemory()
        try dbWrite(database) { try $0.saveAlarmEdit(row, nowMs: 1_000) }
        return (database, try pairedOutbox())
    }

    static func stored(_ database: AppDatabase) throws -> AlarmRow? {
        try dbRead(database) { try $0.alarm(id: alarmID) }
    }

    @Test func newAlarmIsPostedWithItsIdAndAdoptsTheServerVersion() async throws {
        let (database, outbox) = try Self.setup(Self.localAlarm(version: 0))
        let transport = ScriptedTransport()
        await transport.route("/v1/alarms", [.response(Self.serverAlarm(label: "Wake up", version: 5))])
        let engine = makeEngine(database: database, outbox: outbox, transport: transport)

        let result = await engine.pushAlarmEdits()

        #expect(result == SyncEngine.AlarmPushResult(pushed: 1, conflicts: 0, pending: 0))
        let requests = await transport.requests.filter { $0.url.path == "/v1/alarms" }
        #expect(requests.first?.method == "POST")
        #expect(requests.first?.headers["If-Match"] == nil)
        let body = try jsonObject(requests.first?.body)
        #expect(body["id"] as? String == Self.alarmID)
        #expect(body["rhythm"] as? String == "double")
        let row = try #require(try Self.stored(database))
        #expect(row.version == 5)
        #expect(row.dirty == false)
    }

    @Test func editIsPatchedWithIfMatchOfTheLastSeenVersion() async throws {
        let (database, outbox) = try Self.setup(Self.localAlarm(version: 3))
        let transport = ScriptedTransport()
        await transport.route("/v1/alarms/\(Self.alarmID)", [.response(Self.serverAlarm(label: "Wake up", version: 4))])
        let engine = makeEngine(database: database, outbox: outbox, transport: transport)

        let result = await engine.pushAlarmEdits()

        #expect(result.pushed == 1)
        let request = try #require(await transport.requests.first { $0.url.path == "/v1/alarms/\(Self.alarmID)" })
        #expect(request.method == "PATCH")
        #expect(request.headers["If-Match"] == "3")
        #expect(try Self.stored(database)?.version == 4)
    }

    @Test func conflictKeepsTheServerCopyAndCountsOneConflict() async throws {
        let (database, outbox) = try Self.setup(Self.localAlarm(version: 3))
        let transport = ScriptedTransport()
        let conflict = HTTPResponse(status: 409, body: Data("""
        {"type":"urn:icarus:problem:conflict","title":"Conflict","status":409,"detail":"stale",\
        "current":{"id":"\(Self.alarmID)","kind":"scheduled","label":"Server label","schedule":null,"rhythm":"single",\
        "channels":["phone"],"enabled":false,"version":9,"updated_at":"2026-10-07T14:30:00Z","deleted_at":null}}
        """.utf8))
        await transport.route("/v1/alarms/\(Self.alarmID)", [.response(conflict)])
        let engine = makeEngine(database: database, outbox: outbox, transport: transport)

        let result = await engine.pushAlarmEdits()

        #expect(result == SyncEngine.AlarmPushResult(pushed: 0, conflicts: 1, pending: 0))
        let row = try #require(try Self.stored(database))
        #expect(row.label == "Server label")
        #expect(row.version == 9)
        #expect(row.enabled == false)
        #expect(row.dirty == false)
        #expect(await engine.takeAlarmConflicts() == 1)
        #expect(await engine.takeAlarmConflicts() == 0)
    }

    @Test func offlineEditStaysDirtyForTheNextRun() async throws {
        let (database, outbox) = try Self.setup(Self.localAlarm(version: 3))
        let transport = ScriptedTransport()
        await transport.route("/v1/alarms/\(Self.alarmID)", [.failure])
        let engine = makeEngine(database: database, outbox: outbox, transport: transport)

        let result = await engine.pushAlarmEdits()

        #expect(result == SyncEngine.AlarmPushResult(pushed: 0, conflicts: 0, pending: 1))
        #expect(try Self.stored(database)?.dirty == true)
    }

    @Test func deleteSendsIfMatchAndClearsTheDirtyTombstone() async throws {
        let (database, outbox) = try Self.setup(Self.localAlarm(version: 2, deleted: true))
        let transport = ScriptedTransport()
        await transport.route("/v1/alarms/\(Self.alarmID)", [.response(HTTPResponse(status: 204))])
        let engine = makeEngine(database: database, outbox: outbox, transport: transport)

        let result = await engine.pushAlarmEdits()

        #expect(result.pushed == 1)
        let request = try #require(await transport.requests.first { $0.url.path == "/v1/alarms/\(Self.alarmID)" })
        #expect(request.method == "DELETE")
        #expect(request.headers["If-Match"] == "2")
        let row = try #require(try Self.stored(database))
        #expect(row.deletedAt != nil)
        #expect(row.dirty == false)
    }

    @Test func rejectedEditIsDroppedAndCounted() async throws {
        let (database, outbox) = try Self.setup(Self.localAlarm(version: 0))
        let transport = ScriptedTransport()
        await transport.route("/v1/alarms", [.response(problemResponse(400, slug: "validation", detail: "bad rhythm"))])
        let outcome = try await AlarmPusher(
            database: database,
            client: APIClient(baseURL: testServer, token: "device-token", transport: transport, now: { testNow }),
            clock: testClock
        ).run()

        #expect(outcome.rejected == 1)
        #expect(try Self.stored(database)?.dirty == false)
    }

    @Test func pushTokenIsSentWithItsEnvironment() async throws {
        let transport = ScriptedTransport()
        let engine = makeEngine(database: try AppDatabase.inMemory(), outbox: try pairedOutbox(), transport: transport)

        try await engine.sendPushToken("abcd01", environment: .sandbox)

        let request = try #require(await transport.requests.first { $0.url.path == "/v1/devices/me/push-token" })
        #expect(request.method == "PUT")
        #expect(request.headers["Authorization"] == "Bearer device-token")
        let body = try jsonObject(request.body)
        #expect(body["apns_token"] as? String == "abcd01")
        #expect(body["environment"] as? String == "sandbox")
    }

    @Test func pendingDispatchesKeepTheRhythmAsJSON() async throws {
        let transport = ScriptedTransport()
        await transport.route("/v1/alarms/pending", [.response(HTTPResponse(status: 200, body: Data("""
        {"dispatches":[{"id":"d1","alarm_id":null,"delivery_id":"x","created_at":"2026-10-07T14:30:00Z","attempts":1,\
        "phone_status":"sent","band_status":null,"acked_at":null,"status":"pending","message":"Front door opened",\
        "rhythm":[{"type":"buzz","preset":2,"loops":1},{"type":"pause","ms":300}]}]}
        """.utf8)))])
        let engine = makeEngine(database: try AppDatabase.inMemory(), outbox: try pairedOutbox(), transport: transport)

        let dispatches = try await engine.pendingDispatches()

        #expect(dispatches.map(\.id) == ["d1"])
        #expect(dispatches.first?.message == "Front door opened")
        #expect(dispatches.first?.rhythmJSON.contains("\"pause\"") == true)
    }

    @Test func ackSendsBothOutcomesAndAnEmptyDetail() async throws {
        let transport = ScriptedTransport()
        let engine = makeEngine(database: try AppDatabase.inMemory(), outbox: try pairedOutbox(), transport: transport)

        try await engine.ackDispatch(id: "d1", phone: .shown, band: .notConnected)

        let request = try #require(await transport.requests.first { $0.url.path == "/v1/alarm-dispatches/d1/ack" })
        #expect(request.method == "POST")
        let body = try jsonObject(request.body)
        #expect(body["phone"] as? String == "shown")
        #expect(body["band"] as? String == "not_connected")
        #expect(body["detail"] is NSNull)
    }

    @Test func unpairedDeviceCannotCallTheServer() async throws {
        let transport = ScriptedTransport()
        let engine = makeEngine(database: try AppDatabase.inMemory(), outbox: temporaryOutbox(), transport: transport)

        await #expect(throws: APIError.self) {
            try await engine.pendingDispatches()
        }
        #expect(await transport.requests.isEmpty)
    }
}
