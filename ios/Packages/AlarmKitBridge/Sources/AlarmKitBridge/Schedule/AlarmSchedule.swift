import Foundation

/// A repeating alarm time, in the server's wire form: `{"time":"06:30","weekdays":[1,2,3,4,5]}`
/// (api-contract.md, Alarms). Weekdays are ISO numbers, 1 = Monday ... 7 = Sunday. Empty means one-off.
public struct AlarmSchedule: Codable, Equatable, Sendable {
    public let hour: Int
    public let minute: Int
    /// Sorted, unique, each in 1...7.
    public let weekdays: [Int]

    public init?(hour: Int, minute: Int, weekdays: [Int] = []) {
        guard (0...23).contains(hour), (0...59).contains(minute), weekdays.allSatisfy({ (1...7).contains($0) }) else {
            return nil
        }
        self.hour = hour
        self.minute = minute
        self.weekdays = Array(Set(weekdays)).sorted()
    }

    /// "HH:mm", zero-padded, as the server stores it.
    public var time: String {
        Self.pad(hour) + ":" + Self.pad(minute)
    }

    private static func pad(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    private enum CodingKeys: String, CodingKey {
        case time, weekdays
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let text = try container.decode(String.self, forKey: .time)
        let weekdays = try container.decode([Int].self, forKey: .weekdays)
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              let schedule = AlarmSchedule(hour: hour, minute: minute, weekdays: weekdays)
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .time,
                in: container,
                debugDescription: "Expected HH:mm and weekdays 1...7"
            )
        }
        self = schedule
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(time, forKey: .time)
        try container.encode(weekdays, forKey: .weekdays)
    }
}
