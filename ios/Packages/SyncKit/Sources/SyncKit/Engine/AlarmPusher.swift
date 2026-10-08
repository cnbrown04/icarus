import Foundation
import Store

/// Sends local alarm edits, one row at a time, in the order they were made (PLAN.md 11.5).
///
/// Writes send `If-Match` with the last version the phone saw. A 409 keeps the server copy and counts as a conflict.
/// A network failure throws and leaves the row dirty, so the next run sends it again.
struct AlarmPusher {
    let database: AppDatabase
    let client: APIClient
    let clock: SyncClock

    struct Outcome: Equatable, Sendable {
        var pushed = 0
        var conflicts = 0
        var rejected = 0
    }

    private enum Settled {
        case pushed
        case conflict
        case rejected
    }

    func run() async throws -> Outcome {
        let dirty = try await database.writer.read { try $0.dirtyAlarms() }
        var outcome = Outcome()
        for row in dirty {
            switch try await push(row) {
            case .pushed: outcome.pushed += 1
            case .conflict: outcome.conflicts += 1
            case .rejected: outcome.rejected += 1
            }
        }
        return outcome
    }

    private func push(_ row: AlarmRow) async throws -> Settled {
        if row.deletedAt != nil {
            let response = try await client.exchange(
                "DELETE",
                "/v1/alarms/\(row.id)",
                headers: ["If-Match": "\(row.version)"]
            )
            // 404 means the server already has no such alarm, so the delete is done either way.
            if (200..<300).contains(response.status) || response.status == 404 {
                try await markClean(row.id)
                return .pushed
            }
            return try await refused(response, row: row)
        }

        let response: HTTPResponse
        if row.version == 0 {
            response = try await client.exchange("POST", "/v1/alarms", body: try AlarmWire.createBody(row))
        } else {
            response = try await client.exchange(
                "PATCH",
                "/v1/alarms/\(row.id)",
                headers: ["If-Match": "\(row.version)"],
                body: try AlarmWire.editBody(row)
            )
        }
        guard (200..<300).contains(response.status) else {
            return try await refused(response, row: row)
        }
        let alarm = try JSONDecoder().decode(AlarmDTO.self, from: response.body)
        try await apply(alarm)
        return .pushed
    }

    private func refused(_ response: HTTPResponse, row: AlarmRow) async throws -> Settled {
        switch response.status {
        case 409:
            // The server copy wins. Applying it clears the dirty flag.
            if let current = (try? JSONDecoder().decode(AlarmConflict.self, from: response.body))?.current {
                try await apply(current)
            } else {
                try await markClean(row.id)
            }
            return .conflict
        case 401, 408, 425, 429, 500...599:
            // Not this row's fault: the token is gone, or the server is busy. Stop and retry later.
            throw APIError.http(status: response.status, problem: nil, retryAfter: nil)
        default:
            // Any other 4xx will not succeed on retry. Drop the edit and report it, rather than retry forever.
            try await markClean(row.id)
            return .rejected
        }
    }

    private func apply(_ alarm: AlarmDTO) async throws {
        let nowMs = clock.nowMs()
        try await database.writer.write { db in
            try db.applyAlarm(alarm, nowMs: nowMs)
        }
    }

    private func markClean(_ id: String) async throws {
        try await database.writer.write { db in
            try db.markAlarmClean(id: id)
        }
    }
}
