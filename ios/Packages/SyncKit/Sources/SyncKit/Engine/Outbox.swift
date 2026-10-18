import Foundation
import Store

/// A batch that the server refused (4xx). Its rows stay unacknowledged, so the cursor is held back at `floor`.
public struct QuarantineRecord: Codable, Equatable, Sendable {
    public let batchID: String
    public let from: [String: Int64]
    public let to: [String: Int64]
}

/// The server connection and sync bookkeeping that lives outside the store (PLAN.md 11.6).
public struct OutboxState: Codable, Equatable, Sendable {
    /// The active pairing. Nil when unpaired.
    public var connection: ServerConnection?
    /// The last server this device paired with. Kept across unpairing, so re-pairing the same server resumes.
    public var pairedServer: URL?
    public var needsRepair = false
    public var lastSuccessAt: Date?
    public var serverTime: Date?
    public var clockSkewWarning = false
    /// `max_version` from the last config pull, sent back as `since`.
    public var alarmsVersion: Int64 = 0
    /// The server profile version last applied. Nil until a profile with values has been applied.
    public var profileVersion: Int64?
    public var quarantine: [QuarantineRecord] = []
    /// The furthest position sent or quarantined since the last server change, per `SyncStream.rawValue`.
    /// Rows up to here are not built again, even while the cursor is held back by a quarantined batch.
    public var sentThrough: [String: Int64] = [:]

    public init() {}
}

public struct ServerConnection: Codable, Equatable, Sendable {
    public let serverURL: URL
    public let deviceID: UUID

    public init(serverURL: URL, deviceID: UUID) {
        self.serverURL = serverURL
        self.deviceID = deviceID
    }
}

/// Stream positions for a batch file, keyed by `SyncStream.rawValue` for JSON.
struct BatchPositions: Codable, Equatable, Sendable {
    let from: [String: Int64]
    let to: [String: Int64]
}

/// Files next to the store: the state document, each batch body, and the background upload files. Batch bodies
/// hold health data, so the directory belongs in app support with file protection (PLAN.md 7.4, 18).
public struct Outbox: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func loadState() -> OutboxState {
        guard let data = try? Data(contentsOf: stateURL) else { return OutboxState() }
        return (try? JSONDecoder().decode(OutboxState.self, from: data)) ?? OutboxState()
    }

    public func saveState(_ state: OutboxState) throws {
        try write(try JSONEncoder().encode(state), to: stateURL)
    }

    func writeBatch(_ batch: PreparedBatch) throws {
        try write(batch.body, to: bodyURL(batch.id))
        let positions = BatchPositions(from: Self.stored(batch.from), to: Self.stored(batch.to))
        try write(try JSONEncoder().encode(positions), to: positionsURL(batch.id))
    }

    /// The body and positions of a batch, or nil when either file is missing.
    func readBatch(_ id: String) -> (body: Data, from: StreamPositions, to: StreamPositions)? {
        guard let body = try? Data(contentsOf: bodyURL(id)),
              let data = try? Data(contentsOf: positionsURL(id)),
              let positions = try? JSONDecoder().decode(BatchPositions.self, from: data)
        else { return nil }
        return (body, Self.positions(positions.from), Self.positions(positions.to))
    }

    func removeBatch(_ id: String) {
        for url in [bodyURL(id), positionsURL(id), wireURL(id), resultURL(id)] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Writes the wire bytes for a background upload and returns the file to upload from.
    func writeWire(_ body: Data, batchID: String) throws -> URL {
        try write(body, to: wireURL(batchID))
        return wireURL(batchID)
    }

    func readResult(_ id: String) -> BackgroundResult? {
        guard let data = try? Data(contentsOf: resultURL(id)) else { return nil }
        return try? JSONDecoder().decode(BackgroundResult.self, from: data)
    }

    func writeResult(_ result: BackgroundResult, id: String) throws {
        try write(try JSONEncoder().encode(result), to: resultURL(id))
    }

    func removeResult(_ id: String) {
        try? FileManager.default.removeItem(at: resultURL(id))
    }

    /// Replaces the stored webhook endpoint list. The server always sends the full list (api-contract.md, Decisions).
    func writeHooks(_ json: Data) throws {
        try write(json, to: directory.appendingPathComponent("hooks.json"))
    }

    private var stateURL: URL { directory.appendingPathComponent("state.json") }

    private func bodyURL(_ id: String) -> URL {
        directory.appendingPathComponent("batches", isDirectory: true).appendingPathComponent("\(id).json")
    }

    private func positionsURL(_ id: String) -> URL {
        directory.appendingPathComponent("batches", isDirectory: true).appendingPathComponent("\(id).positions.json")
    }

    private func wireURL(_ id: String) -> URL {
        directory.appendingPathComponent("uploads", isDirectory: true).appendingPathComponent("\(id).wire")
    }

    private func resultURL(_ id: String) -> URL {
        directory.appendingPathComponent("results", isDirectory: true).appendingPathComponent("\(id).json")
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func stored(_ positions: StreamPositions) -> [String: Int64] {
        Dictionary(uniqueKeysWithValues: positions.map { ($0.key.rawValue, $0.value) })
    }

    static func positions(_ stored: [String: Int64]) -> StreamPositions {
        var positions: StreamPositions = [:]
        for stream in SyncStream.allCases {
            positions[stream] = stored[stream.rawValue] ?? 0
        }
        return positions
    }
}

/// What the background session writes when an upload finishes (BackgroundUploader, or a test).
public struct BackgroundResult: Codable, Equatable, Sendable {
    /// The HTTP status, or nil when no response arrived.
    public let status: Int?
    public let message: String?
    public let retryAfter: Double?

    public init(status: Int?, message: String?, retryAfter: Double?) {
        self.status = status
        self.message = message
        self.retryAfter = retryAfter
    }
}
