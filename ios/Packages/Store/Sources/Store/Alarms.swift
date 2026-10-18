import Foundation
import GRDB

/// One `alarm` row (PLAN.md 10.2). `schedule`, `rhythm` and `channels` hold the wire JSON exactly as the server
/// names it (api-contract.md, Alarms), so a row round-trips without a second model.
public struct AlarmRow: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "alarm"

    public var id: String
    public var kind: String
    public var label: String
    public var schedule: String?
    public var rhythm: String
    public var channels: String
    public var enabled: Bool
    /// The last version the server sent. 0 means the server has never seen the row.
    public var version: Int64
    public var updatedAt: Int64
    /// Epoch ms of a local delete. A non-nil value is a tombstone the server has not confirmed yet.
    public var deletedAt: Int64?
    /// True while a local edit has not reached the server (PLAN.md 11.5).
    public var dirty: Bool

    public init(
        id: String,
        kind: String = "scheduled",
        label: String,
        schedule: String?,
        rhythm: String,
        channels: String,
        enabled: Bool,
        version: Int64 = 0,
        updatedAt: Int64 = 0,
        deletedAt: Int64? = nil,
        dirty: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.schedule = schedule
        self.rhythm = rhythm
        self.channels = channels
        self.enabled = enabled
        self.version = version
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.dirty = dirty
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, label, schedule, rhythm, channels, enabled, version, dirty
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

/// Alarm reads and local writes (PLAN.md 11.5). Call them inside `DatabaseWriter.write` or `read`.
extension Database {
    /// Live alarms (tombstones excluded), in the order they were created.
    public func alarms() throws -> [AlarmRow] {
        try AlarmRow.fetchAll(self, sql: "SELECT * FROM alarm WHERE deleted_at IS NULL ORDER BY rowid")
    }

    public func alarm(id: String) throws -> AlarmRow? {
        try AlarmRow.fetchOne(self, key: id)
    }

    /// Local edits and tombstones the server has not confirmed, in the order they were made.
    public func dirtyAlarms() throws -> [AlarmRow] {
        try AlarmRow.fetchAll(self, sql: "SELECT * FROM alarm WHERE dirty = 1 ORDER BY rowid")
    }

    /// Stores an edit as dirty. `version` stays what the server last sent, so the next PATCH can send it as If-Match.
    public func saveAlarmEdit(_ row: AlarmRow, nowMs: Int64) throws {
        var edited = row
        edited.dirty = true
        edited.updatedAt = nowMs
        try edited.save(self)
    }

    /// Deletes an alarm locally. One the server has never seen is dropped; any other becomes a dirty tombstone.
    public func deleteAlarmEdit(id: String, nowMs: Int64) throws {
        guard var row = try alarm(id: id) else { return }
        guard row.version > 0 else {
            try execute(sql: "DELETE FROM alarm WHERE id = ?", arguments: [id])
            return
        }
        row.deletedAt = nowMs
        row.dirty = true
        row.updatedAt = nowMs
        try row.save(self)
    }

    /// Clears the dirty flag once the server has taken the edit, or has refused it for good.
    public func markAlarmClean(id: String) throws {
        try execute(sql: "UPDATE alarm SET dirty = 0 WHERE id = ?", arguments: [id])
    }
}
