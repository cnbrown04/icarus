import Foundation
import GRDB
import Store

/// Uploads batches in order, then pulls alarms and profile (PLAN.md 11.3, 11.4). One run at a time.
///
/// Cursors move only on a 2xx (or a duplicate, which is also 2xx). A 4xx quarantines its batch: the cursor stays
/// at the start of that batch, and new rows go out in later batches from a read position past it. Batch rows are
/// acknowledged by the server's natural keys, so a row sent twice has no effect.
public actor SyncEngine {
    /// Device-to-server clock difference that raises the skew warning (PLAN.md 11.5).
    static let skewLimit: TimeInterval = 120
    /// Background uploads start only when the last success is at least this old (PLAN.md 11.2).
    static let backgroundInterval: TimeInterval = 15 * 60
    static let messageLimit = 200

    private let database: AppDatabase
    private let outbox: Outbox
    private let tokens: any TokenStore
    private let transport: any HTTPTransport
    private let clock: SyncClock
    private let builder: BatchBuilder
    private var running: Task<SyncRunResult, Never>?
    private var failures = 0
    private var retryAt: Date?
    /// Alarm conflicts found since the Alarms screen last asked (PLAN.md 11.5).
    private var alarmConflicts = 0

    public init(
        database: AppDatabase,
        outbox: Outbox,
        tokens: any TokenStore,
        transport: any HTTPTransport,
        clock: SyncClock = .system,
        builder: BatchBuilder = BatchBuilder()
    ) {
        self.database = database
        self.outbox = outbox
        self.tokens = tokens
        self.transport = transport
        self.clock = clock
        self.builder = builder
    }

    public func status() -> SyncStatus {
        let state = outbox.loadState()
        return SyncStatus(
            phase: phase(for: state),
            lastSuccessAt: state.lastSuccessAt,
            clockSkewWarning: state.clockSkewWarning,
            quarantinedBatches: state.quarantine.count,
            serverHost: state.connection?.serverURL.host
        )
    }

    /// Runs one pass: batches still pending, then new batches, then config. A call made during a run waits for it.
    public func run() async -> SyncRunResult {
        if let running {
            return await running.value
        }
        let task = Task { await self.runOnce() }
        running = task
        let result = await task.value
        running = nil
        return result
    }

    /// Exchanges a pairing code for a device token (PLAN.md 11.6). Throws `APIError`, for example
    /// `.http` with slug `pairing-code-invalid` for a bad or used code.
    public func pair(serverURL: URL, code: String, device: DeviceInfo) async throws {
        let client = APIClient(baseURL: serverURL, token: nil, transport: transport, now: clock.now)
        let body = try JSONEncoder().encode(PairRequest(
            code: code,
            name: device.name,
            model: device.model,
            osVersion: device.osVersion,
            appVersion: device.appVersion
        ))
        let response = try await client.json(PairResponse.self, "POST", "/v1/devices/pair", body: body)
        try tokens.save(response.token)

        var state = outbox.loadState()
        if state.pairedServer != serverURL {
            // A different server has none of this device's rows yet, so everything local is sent again.
            try await resetCursors()
            state.quarantine = []
            state.sentThrough = [:]
            state.alarmsVersion = 0
            state.profileVersion = nil
        }
        try await dropOpenBatches()
        state.pairedServer = serverURL
        state.connection = ServerConnection(serverURL: serverURL, deviceID: response.deviceID)
        state.needsRepair = false
        try outbox.saveState(state)
        failures = 0
        retryAt = nil
    }

    /// Forgets the token and the connection. Local data stays; nothing is revoked on the server (the web app does that).
    public func unpair() async throws {
        try tokens.delete()
        var state = outbox.loadState()
        state.connection = nil
        state.needsRepair = false
        state.clockSkewWarning = false
        try await dropOpenBatches()
        try outbox.saveState(state)
        failures = 0
        retryAt = nil
    }

    #if canImport(Darwin)
    /// Starts an upload on the background session when the last success is old enough (PLAN.md 11.2).
    /// Returns false when nothing was queued.
    public func enqueueBackgroundUpload(_ uploader: BackgroundUploader) async -> Bool {
        let state = outbox.loadState()
        guard let connection = state.connection, !state.needsRepair, let token = try? tokens.load() else { return false }
        if let last = state.lastSuccessAt, clock.now().timeIntervalSince(last) < Self.backgroundInterval {
            return false
        }
        do {
            let open = try await database.writer.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_batch_log WHERE status IN ('pending', 'sent')") ?? 0
            }
            guard open == 0, let batch = try await nextNewBatch() else { return false }
            let (wire, encoding) = BodyEncoding.encode(batch.body)
            let file = try outbox.writeWire(wire, batchID: batch.id)
            try await database.writer.write { db in
                try db.updateSyncBatch(id: batch.id, status: "sent", httpStatus: nil, error: nil)
            }
            let client = APIClient(baseURL: connection.serverURL, token: token, transport: transport, now: clock.now)
            uploader.enqueue(
                batchID: batch.id,
                file: file,
                request: try client.batchRequest(batchID: batch.id, contentEncoding: encoding, body: nil)
            )
            return true
        } catch {
            return false
        }
    }
    #endif

    // MARK: Run

    private func runOnce() async -> SyncRunResult {
        let state = outbox.loadState()
        guard let connection = state.connection else { return .notPaired }
        guard !state.needsRepair else { return .needsRepair }
        guard let token = try? tokens.load() else { return .notPaired }
        retryAt = nil
        let client = APIClient(baseURL: connection.serverURL, token: token, transport: transport, now: clock.now)
        do {
            if try await reconcileSentBatches() == .repair {
                return .needsRepair
            }
            while let batch = try await nextBatch() {
                switch await send(batch, client: client) {
                case .delivered, .quarantined:
                    continue
                case let .retry(after):
                    return scheduleRetry(after: after)
                case .repair:
                    return .needsRepair
                }
            }
            try await pushAlarms(client)
            try await pullConfig(client)
            try finishSuccess()
            return .synced
        } catch let error as APIError {
            if case let .http(status, _, retryAfter) = error {
                if status == 401 {
                    markNeedsRepair()
                    return .needsRepair
                }
                return scheduleRetry(after: retryAfter)
            }
            return scheduleRetry(after: nil)
        } catch {
            return scheduleRetry(after: nil)
        }
    }

    private enum Delivery: Equatable {
        case delivered
        case quarantined
        case retry(after: TimeInterval?)
        case repair
    }

    private func send(_ batch: PreparedBatch, client: APIClient) async -> Delivery {
        let (wire, encoding) = BodyEncoding.encode(batch.body)
        do {
            let receipt = try await client.postBatch(body: wire, batchID: batch.id, contentEncoding: encoding)
            noteServerTime(receipt.serverTime)
            try await acknowledge(batch, httpStatus: receipt.status)
            return .delivered
        } catch let error as APIError {
            return (try? await handle(error, batch: batch)) ?? .retry(after: nil)
        } catch {
            return .retry(after: nil)
        }
    }

    /// Maps a failed upload to its next step (PLAN.md 11.3). Only 401 means the token is gone. A 404 is treated as
    /// a server or path problem, not a bad batch, so it retries.
    private func handle(_ error: APIError, batch: PreparedBatch) async throws -> Delivery {
        switch error {
        case let .http(status, problem, retryAfter):
            let message = Self.message(status: status, problem: problem)
            switch status {
            case 401:
                try await markPending(batch.id, httpStatus: status, message: message)
                markNeedsRepair()
                return .repair
            case 404, 408, 425, 429, 500...599:
                try await markPending(batch.id, httpStatus: status, message: message)
                return .retry(after: retryAfter)
            case 400...499:
                try await quarantine(batch, httpStatus: status, message: message)
                return .quarantined
            default:
                try await markPending(batch.id, httpStatus: status, message: message)
                return .retry(after: retryAfter)
            }
        case .network, .invalidServerURL, .decoding:
            try await markPending(batch.id, httpStatus: nil, message: "Network unavailable")
            return .retry(after: nil)
        }
    }

    private func scheduleRetry(after serverDelay: TimeInterval?) -> SyncRunResult {
        let delay = Backoff.delay(attempt: failures, retryAfter: serverDelay, uniform: clock.uniform)
        failures += 1
        let at = clock.now().addingTimeInterval(delay)
        retryAt = at
        return .retry(at: at)
    }

    private func phase(for state: OutboxState) -> SyncPhase {
        guard state.connection != nil else { return .notPaired }
        if state.needsRepair { return .needsRepair }
        if running != nil { return .syncing }
        if let retryAt, retryAt > clock.now() { return .retrying(at: retryAt) }
        return .idle
    }

    // MARK: Batches

    /// The oldest pending batch, or a new one built from the read positions. Nil when nothing is left to send.
    private func nextBatch() async throws -> PreparedBatch? {
        let database = database
        let outbox = outbox
        while let id = try await database.writer.read({ db in
            try String.fetchOne(db, sql: "SELECT batch_id FROM sync_batch_log WHERE status = 'pending' ORDER BY rowid LIMIT 1")
        }) {
            if let stored = outbox.readBatch(id) {
                return PreparedBatch(id: id, body: stored.body, rowCount: 0, from: stored.from, to: stored.to)
            }
            // Without its positions the batch cannot be held back, so it is marked rejected and not sent again.
            try await database.writer.write { db in
                try db.updateSyncBatch(id: id, status: "rejected", httpStatus: nil, error: "Batch file missing")
            }
        }
        return try await nextNewBatch()
    }

    private func nextNewBatch() async throws -> PreparedBatch? {
        let database = database
        let outbox = outbox
        let builder = builder
        let clock = clock
        let state = outbox.loadState()
        guard let deviceID = state.connection?.deviceID else { return nil }
        let sentThrough = state.sentThrough
        let nowMs = clock.nowMs()
        let batchID = UUIDv7.make(unixMs: nowMs)
        return try await database.writer.write { db -> PreparedBatch? in
            let from = try Self.readPositions(db, sentThrough: sentThrough)
            guard let batch = try builder.build(db, deviceID: deviceID, from: from, batchID: batchID, nowMs: nowMs) else {
                return nil
            }
            try db.recordSyncBatch(id: batch.id, createdAtMs: nowMs, rows: batch.rowCount, status: "pending")
            try outbox.writeBatch(batch)
            return batch
        }
    }

    /// Read position per stream: the acknowledged cursor, or the furthest position sent if that is further on.
    static func readPositions(_ db: Database, sentThrough: [String: Int64]) throws -> StreamPositions {
        var positions: StreamPositions = [:]
        for stream in SyncStream.allCases {
            positions[stream] = max(try db.syncCursor(stream), sentThrough[stream.rawValue] ?? 0)
        }
        return positions
    }

    /// `sent` moved forward to the end of every stream that had rows in the batch.
    static func advanced(_ sent: [String: Int64], to end: StreamPositions, from start: StreamPositions) -> [String: Int64] {
        var result = sent
        for stream in SyncStream.allCases where (end[stream] ?? 0) > (start[stream] ?? 0) {
            result[stream.rawValue] = max(result[stream.rawValue] ?? 0, end[stream] ?? 0)
        }
        return result
    }

    /// The cursor may not move past the start of a quarantined batch. Only streams with rows in that batch count.
    static func floors(_ quarantine: [QuarantineRecord]) -> StreamPositions {
        var floors: StreamPositions = [:]
        for record in quarantine {
            for stream in SyncStream.allCases {
                let from = record.from[stream.rawValue] ?? 0
                let to = record.to[stream.rawValue] ?? 0
                guard to > from else { continue }
                floors[stream] = min(floors[stream] ?? from, from)
            }
        }
        return floors
    }

    private func acknowledge(_ batch: PreparedBatch, httpStatus: Int) async throws {
        let database = database
        let outbox = outbox
        let nowMs = clock.nowMs()
        let floors = Self.floors(outbox.loadState().quarantine)
        try await database.writer.write { db in
            for stream in SyncStream.allCases {
                let start = batch.from[stream] ?? 0
                let end = batch.to[stream] ?? 0
                guard end > start else { continue }
                try db.advanceSyncCursor(stream, to: min(end, floors[stream] ?? end), succeededAtMs: nowMs)
            }
            try db.updateSyncBatch(id: batch.id, status: "acked", httpStatus: httpStatus, error: nil)
        }
        var state = outbox.loadState()
        state.sentThrough = Self.advanced(state.sentThrough, to: batch.to, from: batch.from)
        try outbox.saveState(state)
        outbox.removeBatch(batch.id)
    }

    private func quarantine(_ batch: PreparedBatch, httpStatus: Int, message: String) async throws {
        let database = database
        try await database.writer.write { db in
            try db.updateSyncBatch(id: batch.id, status: "rejected", httpStatus: httpStatus, error: message)
        }
        var state = outbox.loadState()
        state.quarantine.append(QuarantineRecord(
            batchID: batch.id,
            from: Outbox.stored(batch.from),
            to: Outbox.stored(batch.to)
        ))
        state.sentThrough = Self.advanced(state.sentThrough, to: batch.to, from: batch.from)
        try outbox.saveState(state)
    }

    private func markPending(_ id: String, httpStatus: Int?, message: String) async throws {
        let database = database
        try await database.writer.write { db in
            try db.updateSyncBatch(id: id, status: "pending", httpStatus: httpStatus, error: message)
        }
    }

    /// Settles batches that went out on the background session. Without a result file the batch is sent again,
    /// which the idempotency key makes safe. Returns `.repair` when a result says the token was refused.
    private func reconcileSentBatches() async throws -> Delivery {
        let database = database
        let ids = try await database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT batch_id FROM sync_batch_log WHERE status = 'sent' ORDER BY rowid")
        }
        var outcome: Delivery = .delivered
        for id in ids {
            guard let stored = outbox.readBatch(id) else {
                try await database.writer.write { db in
                    try db.updateSyncBatch(id: id, status: "rejected", httpStatus: nil, error: "Batch file missing")
                }
                continue
            }
            let batch = PreparedBatch(id: id, body: stored.body, rowCount: 0, from: stored.from, to: stored.to)
            guard let result = outbox.readResult(id) else {
                try await markPending(id, httpStatus: nil, message: "Upload not confirmed")
                continue
            }
            outbox.removeResult(id)
            if let status = result.status, (200..<300).contains(status) {
                try await acknowledge(batch, httpStatus: status)
                continue
            }
            let error: APIError = result.status.map {
                .http(status: $0, problem: nil, retryAfter: result.retryAfter)
            } ?? .network(result.message ?? "Upload failed")
            if try await handle(error, batch: batch) == .repair {
                outcome = .repair
            }
        }
        return outcome
    }

    // MARK: Alarms and push (PLAN.md 9.3, 11.5, 12.5)

    /// What one `pushAlarmEdits` call achieved. `pending` counts edits still waiting for the server.
    public struct AlarmPushResult: Equatable, Sendable {
        public let pushed: Int
        public let conflicts: Int
        public let pending: Int
    }

    /// Sends local alarm edits now, for the editor's Save. Edits that cannot be sent (offline, not paired) stay dirty
    /// and go out on the next run.
    public func pushAlarmEdits() async -> AlarmPushResult {
        guard let client = authorizedClient() else {
            return AlarmPushResult(pushed: 0, conflicts: 0, pending: await dirtyAlarmCount())
        }
        do {
            let outcome = try await AlarmPusher(database: database, client: client, clock: clock).run()
            alarmConflicts += outcome.conflicts
            return AlarmPushResult(
                pushed: outcome.pushed,
                conflicts: outcome.conflicts,
                pending: await dirtyAlarmCount()
            )
        } catch {
            return AlarmPushResult(pushed: 0, conflicts: 0, pending: await dirtyAlarmCount())
        }
    }

    /// Conflicts found since the last call, then reset to zero.
    public func takeAlarmConflicts() -> Int {
        let count = alarmConflicts
        alarmConflicts = 0
        return count
    }

    /// Registers the device's APNs token for this environment (`PUT /v1/devices/me/push-token`). Throws when not paired.
    public func sendPushToken(_ hex: String, environment: PushEnvironment) async throws {
        guard let client = authorizedClient() else { throw APIError.network("Not paired") }
        let body = try JSONEncoder().encode(PushTokenBody(apnsToken: hex, environment: environment.rawValue))
        _ = try await client.send("PUT", "/v1/devices/me/push-token", body: body)
    }

    /// Dispatches the server has not seen acked (`GET /v1/alarms/pending`). Throws when not paired.
    public func pendingDispatches() async throws -> [PendingDispatch] {
        guard let client = authorizedClient() else { throw APIError.network("Not paired") }
        return try await client.json(PendingResponse.self, "GET", "/v1/alarms/pending").dispatches
    }

    /// Reports what the phone and the band did for a dispatch (`POST /v1/alarm-dispatches/{id}/ack`).
    public func ackDispatch(id: String, phone: PhoneAck, band: BandAck, detail: String? = nil) async throws {
        guard let client = authorizedClient() else { throw APIError.network("Not paired") }
        let body = try JSONEncoder().encode(AckBody(phone: phone.rawValue, band: band.rawValue, detail: detail))
        _ = try await client.send("POST", "/v1/alarm-dispatches/\(id)/ack", body: body)
    }

    /// Dirty alarms go out before the config pull, so a pull cannot overwrite an edit that is still waiting.
    private func pushAlarms(_ client: APIClient) async throws {
        let outcome = try await AlarmPusher(database: database, client: client, clock: clock).run()
        alarmConflicts += outcome.conflicts
    }

    /// A client for the paired server, or nil when the device is not paired or its token is gone.
    private func authorizedClient() -> APIClient? {
        guard let connection = outbox.loadState().connection, let token = try? tokens.load() else { return nil }
        return APIClient(baseURL: connection.serverURL, token: token, transport: transport, now: clock.now)
    }

    private func dirtyAlarmCount() async -> Int {
        (try? await database.writer.read { try $0.dirtyAlarms().count }) ?? 0
    }

    // MARK: Config (PLAN.md 11.4)

    private func pullConfig(_ client: APIClient) async throws {
        let state = outbox.loadState()
        let response = try await client.json(
            ConfigResponse.self,
            "GET",
            "/v1/sync/config",
            query: [URLQueryItem(name: "since", value: String(state.alarmsVersion))]
        )
        let nowMs = clock.nowMs()
        // The profile is applied when the server has values and this version is newer than the last one applied.
        // An empty server profile never overwrites what the user entered on this phone.
        let profileToApply: ProfileDTO? = {
            guard let profile = response.profile, profile.hasValues else { return nil }
            guard let applied = state.profileVersion else { return profile }
            return profile.version > applied ? profile : nil
        }()
        let database = database
        try await database.writer.write { db in
            for alarm in response.alarms {
                try db.applyAlarm(alarm, nowMs: nowMs)
            }
            if let profileToApply {
                try db.applyProfile(profileToApply, nowMs: nowMs)
            }
        }
        try outbox.writeHooks(try JSONEncoder().encode(response.webhookEndpoints))
        var updated = outbox.loadState()
        updated.alarmsVersion = response.maxVersion
        if let profileToApply {
            updated.profileVersion = profileToApply.version
        }
        try outbox.saveState(updated)
        noteServerTime(response.serverTime)
    }

    // MARK: State

    private func finishSuccess() throws {
        var state = outbox.loadState()
        state.lastSuccessAt = clock.now()
        try outbox.saveState(state)
        failures = 0
        retryAt = nil
    }

    private func noteServerTime(_ text: String?) {
        guard let text, let serverTime = RFC3339.date(text) else { return }
        var state = outbox.loadState()
        state.serverTime = serverTime
        state.clockSkewWarning = abs(clock.now().timeIntervalSince(serverTime)) > Self.skewLimit
        try? outbox.saveState(state)
    }

    private func markNeedsRepair() {
        var state = outbox.loadState()
        state.needsRepair = true
        try? outbox.saveState(state)
    }

    private func resetCursors() async throws {
        let database = database
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM sync_cursor")
        }
    }

    /// Drops batches that were built for the previous device identity. Rows stay in the store and are built again.
    private func dropOpenBatches() async throws {
        let database = database
        let outbox = outbox
        let ids = try await database.writer.write { db -> [String] in
            let ids = try String.fetchAll(db, sql: "SELECT batch_id FROM sync_batch_log WHERE status IN ('pending', 'sent')")
            try db.execute(sql: "DELETE FROM sync_batch_log WHERE status IN ('pending', 'sent')")
            return ids
        }
        for id in ids {
            outbox.removeBatch(id)
        }
    }

    private static func message(status: Int, problem: Problem?) -> String {
        let text = problem?.detail ?? problem?.title ?? "HTTP \(status)"
        return String(text.prefix(messageLimit))
    }
}

/// Body of `POST /v1/devices/pair` (api-contract.md).
private struct PairRequest: Encodable {
    let code: String
    let name: String
    let model: String
    let osVersion: String
    let appVersion: String

    enum CodingKeys: String, CodingKey {
        case code, name, model
        case osVersion = "os_version"
        case appVersion = "app_version"
    }
}
