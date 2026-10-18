import Foundation
import GRDB
import Store
import Testing
@testable import SyncKit

/// Synchronous GRDB access. Inside async tests, `writer.read` and `writer.write` would resolve to the async overloads.
@discardableResult
func dbWrite<T>(_ database: AppDatabase, _ body: (Database) throws -> T) throws -> T {
    try database.writer.write(body)
}

func dbRead<T>(_ database: AppDatabase, _ body: (Database) throws -> T) throws -> T {
    try database.writer.read(body)
}

/// 2026-10-07T14:30:00Z, a minute boundary.
let testNow = Date(timeIntervalSince1970: 1_791_383_400)
let testBandPeripheral = UUID(uuidString: "6C1F3A10-2B7D-4E0A-9C11-0000000000B1")!
let testDeviceID = UUID(uuidString: "0192F6C1-7A3E-7C4D-9B1E-0000000000D1")!
let testServer = URL(string: "https://icarus.test")!

/// Fixed time, and a jitter that always returns the top of its range, so delays are exact.
let testClock = SyncClock(now: { testNow }, uniform: { $0 })

enum ScriptedStep: Sendable {
    case response(HTTPResponse)
    case failure
}

/// Answers by path. Batch uploads take scripted steps in order and get a 200 receipt once the script runs out.
actor ScriptedTransport: HTTPTransport {
    private(set) var requests: [HTTPRequest] = []
    private var batchSteps: [ScriptedStep] = []
    private var configResponse: HTTPResponse?
    private var pairResponse: HTTPResponse?
    private var routed: [String: [ScriptedStep]] = [:]

    /// Queues answers for one path, used in order. Paths with no queue fall back to the defaults below.
    func route(_ path: String, _ steps: [ScriptedStep]) {
        routed[path, default: []] += steps
    }

    func queueBatch(_ step: ScriptedStep) {
        batchSteps.append(step)
    }

    func setConfig(_ response: HTTPResponse) {
        configResponse = response
    }

    func setPair(_ response: HTTPResponse) {
        pairResponse = response
    }

    func batchRequests() -> [HTTPRequest] {
        requests.filter { $0.url.path == "/v1/sync/batches" }
    }

    func configRequests() -> [HTTPRequest] {
        requests.filter { $0.url.path == "/v1/sync/config" }
    }

    func perform(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        let path = request.url.path
        if var queue = routed[path], !queue.isEmpty {
            let step = queue.removeFirst()
            routed[path] = queue
            switch step {
            case let .response(response): return response
            case .failure: throw URLError(.notConnectedToInternet)
            }
        }
        switch request.url.path {
        case "/v1/sync/batches":
            guard !batchSteps.isEmpty else { return receipt() }
            switch batchSteps.removeFirst() {
            case let .response(response): return response
            case .failure: throw URLError(.notConnectedToInternet)
            }
        case "/v1/sync/config":
            return configResponse ?? config()
        case "/v1/devices/pair":
            return pairResponse ?? HTTPResponse(status: 201, body: Data(#"{"device_id":"\#(testDeviceID.uuidString.lowercased())","token":"new-token"}"#.utf8))
        default:
            return HTTPResponse(status: 200, body: Data("{}".utf8))
        }
    }

    private func receipt() -> HTTPResponse {
        HTTPResponse(status: 200, body: Data(#"{"batch_id":"x","duplicate":false,"server_time":"2026-10-07T14:30:00Z","counts":{}}"#.utf8))
    }

    private func config() -> HTTPResponse {
        HTTPResponse(status: 200, body: Data(#"{"alarms":[],"webhook_endpoints":[],"profile":null,"max_version":0,"server_time":"2026-10-07T14:30:00Z"}"#.utf8))
    }
}

func problemResponse(_ status: Int, slug: String, detail: String, headers: [String: String] = [:]) -> HTTPResponse {
    let body = #"{"type":"urn:icarus:problem:\#(slug)","title":"Problem","status":\#(status),"detail":"\#(detail)"}"#
    return HTTPResponse(status: status, headers: headers, body: Data(body.utf8))
}

func temporaryOutbox() -> Outbox {
    Outbox(directory: FileManager.default.temporaryDirectory.appendingPathComponent("synckit-\(UUID().uuidString)"))
}

/// A store with a band and `count` heart-rate rows at one-second spacing from `startMs`.
func databaseWithReadings(_ count: Int, startMs: Int64 = 1_000) throws -> AppDatabase {
    let database = try AppDatabase.inMemory()
    try database.writer.write { db in
        let readings = (0..<count).map { index in
            Database.Reading(
                peripheralUUID: testBandPeripheral,
                tsMs: startMs + Int64(index) * 1000,
                bpm: 60,
                contact: true,
                rr: []
            )
        }
        try db.insertReadings(readings)
    }
    return database
}

/// Parsed contract body, for assertions on the JSON the server would receive.
func jsonObject(_ data: Data?) throws -> [String: Any] {
    let data = try #require(data)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// A paired outbox, so engine tests start from a connected device without a pairing round trip.
func pairedOutbox(serverURL: URL = testServer) throws -> Outbox {
    let outbox = temporaryOutbox()
    var state = OutboxState()
    state.connection = ServerConnection(serverURL: serverURL, deviceID: testDeviceID)
    state.pairedServer = serverURL
    try outbox.saveState(state)
    return outbox
}

func makeEngine(
    database: AppDatabase,
    outbox: Outbox,
    transport: ScriptedTransport,
    token: String? = "device-token",
    builder: BatchBuilder = BatchBuilder()
) -> SyncEngine {
    SyncEngine(
        database: database,
        outbox: outbox,
        tokens: InMemoryTokenStore(token: token),
        transport: transport,
        clock: testClock,
        builder: builder
    )
}

func acknowledgedCursor(_ database: AppDatabase, _ stream: SyncStream) throws -> Int64 {
    try database.writer.read { try $0.syncCursor(stream) }
}

func batchLogStatuses(_ database: AppDatabase) throws -> [String] {
    try database.writer.read { db in
        try String.fetchAll(db, sql: "SELECT status FROM sync_batch_log ORDER BY rowid")
    }
}
