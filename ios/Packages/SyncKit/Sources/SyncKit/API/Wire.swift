import Foundation

// Response bodies from api-contract.md. Explicit keys, so the wire names live here and nowhere else.

struct PairResponse: Decodable, Sendable {
    let deviceID: UUID
    let token: String

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case token
    }
}

/// `GET /v1/sync/config` body.
struct ConfigResponse: Decodable, Sendable {
    let alarms: [AlarmDTO]
    let webhookEndpoints: [JSONValue]
    let profile: ProfileDTO?
    let maxVersion: Int64
    let serverTime: String?

    enum CodingKeys: String, CodingKey {
        case alarms
        case webhookEndpoints = "webhook_endpoints"
        case profile
        case maxVersion = "max_version"
        case serverTime = "server_time"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        alarms = try container.decode([AlarmDTO].self, forKey: .alarms)
        webhookEndpoints = try container.decodeIfPresent([JSONValue].self, forKey: .webhookEndpoints) ?? []
        profile = try container.decodeIfPresent(ProfileDTO.self, forKey: .profile)
        maxVersion = try container.decode(Int64.self, forKey: .maxVersion)
        serverTime = try container.decodeIfPresent(String.self, forKey: .serverTime)
    }
}

struct AlarmDTO: Decodable, Sendable {
    let id: String
    let kind: String
    let label: String
    let schedule: JSONValue?
    let rhythm: JSONValue
    let channels: [String]
    let enabled: Bool
    let version: Int64
    let updatedAt: String
    let deletedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, label, schedule, rhythm, channels, enabled, version
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

struct ProfileDTO: Decodable, Sendable {
    let formulaSex: String?
    let birthYear: Int?
    let heightCm: Double?
    let weightKg: Double?
    let hrMax: Int?
    let tz: String?
    let version: Int64

    enum CodingKeys: String, CodingKey {
        case formulaSex = "formula_sex"
        case birthYear = "birth_year"
        case heightCm = "height_cm"
        case weightKg = "weight_kg"
        case hrMax = "hr_max"
        case tz, version
    }

    /// True when the server has any profile field. An empty profile must not overwrite local onboarding data.
    var hasValues: Bool {
        formulaSex != nil || birthYear != nil || heightCm != nil || weightKg != nil || hrMax != nil
    }
}

/// Any JSON value. Used where the app stores a server document as-is (schedule, rhythm, hooks, event payloads).
enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    /// The value as compact JSON text, or nil when it cannot be encoded.
    var text: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

extension JSONValue {
    /// Parses stored JSON text, such as an alarm's rhythm. Nil when the text is not JSON.
    static func parse(_ text: String) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }
}

/// RFC 3339 UTC times with `Z` (api-contract.md, Conventions). Fractional seconds are accepted on input.
enum RFC3339 {
    static func string(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}
