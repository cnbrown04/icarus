import Foundation
import Store
import Testing
@testable import SyncKit

struct PairingTests {
    @Test func normalizesCodesAndRejectsOtherAlphabets() {
        #expect(PairingCode.normalized("k7q2-m9xd") == "K7Q2M9XD")
        #expect(PairingCode.normalized(" K7Q2 M9XD ") == "K7Q2M9XD")
        #expect(PairingCode.normalized("K7Q2M9X") == nil)
        #expect(PairingCode.normalized("K7Q2M9XO") == nil)
        #expect(PairingCode.normalized("K7Q2M9X0") == nil)
    }

    @Test func parsesThePairingLink() throws {
        let url = try #require(URL(string: "icarus://pair?code=k7q2m9xd&server=https%3A%2F%2Ficarus.example.com"))
        let link = try #require(PairingLink(url: url))
        #expect(link.code == "K7Q2M9XD")
        #expect(link.serverURL?.absoluteString == "https://icarus.example.com")
    }

    @Test func ignoresOtherLinks() throws {
        let other = try #require(URL(string: "https://icarus.example.com/pair?code=K7Q2M9XD"))
        #expect(PairingLink(url: other) == nil)
        let wrongHost = try #require(URL(string: "icarus://alarm?code=K7Q2M9XD"))
        #expect(PairingLink(url: wrongHost) == nil)
    }

    @Test func pairingStoresTheTokenAndConnection() async throws {
        let transport = ScriptedTransport()
        let database = try AppDatabase.inMemory()
        let outbox = temporaryOutbox()
        let tokens = InMemoryTokenStore()
        let engine = SyncEngine(database: database, outbox: outbox, tokens: tokens, transport: transport, clock: testClock)
        let device = DeviceInfo(name: "iPhone", model: "iPhone17,1", osVersion: "26.0", appVersion: "0.1.0")

        try await engine.pair(serverURL: testServer, code: "K7Q2M9XD", device: device)

        #expect(try tokens.load() == "new-token")
        let state = outbox.loadState()
        #expect(state.connection == ServerConnection(serverURL: testServer, deviceID: testDeviceID))
        #expect(state.pairedServer == testServer)
        let request = try #require(await transport.requests.first)
        #expect(request.headers["Authorization"] == nil)
        let body = try jsonObject(request.body)
        #expect(body["code"] as? String == "K7Q2M9XD")
        #expect(body["os_version"] as? String == "26.0")
        #expect(body["app_version"] as? String == "0.1.0")
        #expect(await engine.status().phase == SyncPhase.idle)
    }

    @Test func badCodeThrowsTheProblemSlugAndStoresNothing() async throws {
        let transport = ScriptedTransport()
        await transport.setPair(problemResponse(400, slug: "pairing-code-invalid", detail: "Code expired"))
        let tokens = InMemoryTokenStore()
        let engine = SyncEngine(
            database: try AppDatabase.inMemory(),
            outbox: temporaryOutbox(),
            tokens: tokens,
            transport: transport,
            clock: testClock
        )
        let device = DeviceInfo(name: "iPhone", model: "iPhone", osVersion: "26.0", appVersion: "0.1.0")
        do {
            try await engine.pair(serverURL: testServer, code: "K7Q2M9XD", device: device)
            Issue.record("Expected pairing to fail")
        } catch let APIError.http(status, problem, _) {
            #expect(status == 400)
            #expect(problem?.slug == "pairing-code-invalid")
        }
        #expect(try tokens.load() == nil)
        #expect(await engine.status().phase == SyncPhase.notPaired)
    }

    @Test func unpairKeepsLocalRowsAndForgetsTheToken() async throws {
        let database = try databaseWithReadings(3)
        let tokens = InMemoryTokenStore(token: "device-token")
        let outbox = try pairedOutbox()
        let engine = SyncEngine(database: database, outbox: outbox, tokens: tokens, transport: ScriptedTransport(), clock: testClock)

        try await engine.unpair()

        #expect(try tokens.load() == nil)
        #expect(await engine.status().phase == SyncPhase.notPaired)
        #expect(outbox.loadState().pairedServer == testServer)
        let rows = try dbRead(database) { try $0.heartRateRows(from: 0, to: 10_000) }
        #expect(rows.count == 3)
    }
}

struct TokenStoreTests {
    @Test func inMemoryStoreRoundTrips() throws {
        let store = InMemoryTokenStore()
        #expect(try store.load() == nil)
        try store.save("abc")
        #expect(try store.load() == "abc")
        try store.delete()
        #expect(try store.load() == nil)
    }
}
