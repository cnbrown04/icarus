import Foundation
import Store

// Alarm and push calls (api-contract.md, Alarms and Devices; PLAN.md 9.3, 11.5, 12.5).

/// Which APNs environment the token belongs to. Debug builds use sandbox, TestFlight and App Store use production.
public enum PushEnvironment: String, Sendable {
    case sandbox
    case production
}

/// The phone's part of a dispatch ack (api-contract.md, Alarms).
public enum PhoneAck: String, Sendable {
    case shown
    case failed
}

/// The band's part of a dispatch ack (api-contract.md, Alarms).
public enum BandAck: String, Sendable {
    case ok
    case notConnected = "not_connected"
    case disabled
    case failed
}

/// One dispatch from `GET /v1/alarms/pending`. The rhythm stays as wire JSON, so the caller can decode it with
/// AlarmKitBridge's `RhythmSpec`, which SyncKit does not depend on.
public struct PendingDispatch: Equatable, Sendable, Decodable {
    public let id: String
    public let alarmID: String?
    public let status: String
    public let message: String?
    /// A built-in name such as `"double"`, or an array of steps, as JSON text.
    public let rhythmJSON: String

    enum CodingKeys: String, CodingKey {
        case id, status, message, rhythm
        case alarmID = "alarm_id"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        alarmID = try container.decodeIfPresent(String.self, forKey: .alarmID)
        status = try container.decode(String.self, forKey: .status)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        rhythmJSON = try container.decode(JSONValue.self, forKey: .rhythm).text ?? "[]"
    }
}

struct PendingResponse: Decodable, Sendable {
    let dispatches: [PendingDispatch]
}

/// `PUT /v1/devices/me/push-token` body.
struct PushTokenBody: Encodable {
    let apnsToken: String
    let environment: String

    enum CodingKeys: String, CodingKey {
        case apnsToken = "apns_token"
        case environment
    }
}

/// `POST /v1/alarm-dispatches/{id}/ack` body. `detail` is always sent, as null when there is none.
struct AckBody: Encodable {
    let phone: String
    let band: String
    let detail: String?

    enum CodingKeys: String, CodingKey {
        case phone, band, detail
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(phone, forKey: .phone)
        try container.encode(band, forKey: .band)
        // `encode`, not `encodeIfPresent`, so a nil detail is sent as null.
        try container.encode(detail, forKey: .detail)
    }
}

/// Body of a 409 on an alarm write: the server's current copy.
struct AlarmConflict: Decodable, Sendable {
    let current: AlarmDTO?
}

/// The JSON an alarm write sends, built from the stored text so rhythm and schedule keep their wire shape.
enum AlarmWire {
    static func fields(_ row: AlarmRow) -> [String: JSONValue] {
        [
            "kind": .string(row.kind),
            "label": .string(row.label),
            "schedule": row.schedule.flatMap(JSONValue.parse) ?? .null,
            "rhythm": JSONValue.parse(row.rhythm) ?? .array([]),
            "channels": JSONValue.parse(row.channels) ?? .array([]),
            "enabled": .bool(row.enabled),
        ]
    }

    /// `POST /v1/alarms` also takes the client-made id, so the server keeps the one the phone already shows.
    static func createBody(_ row: AlarmRow) throws -> Data {
        var fields = fields(row)
        fields["id"] = .string(row.id)
        return try JSONEncoder().encode(JSONValue.object(fields))
    }

    static func editBody(_ row: AlarmRow) throws -> Data {
        try JSONEncoder().encode(JSONValue.object(fields(row)))
    }
}
