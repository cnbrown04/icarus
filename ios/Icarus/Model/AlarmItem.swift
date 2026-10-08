import AlarmKitBridge
import Foundation
import Store

/// A channel an alarm rings on (api-contract.md, Alarms). The phone is always armed (PLAN.md 6.5), so it is not a choice.
enum AlarmChannel: String, CaseIterable, Sendable {
    case phone
    case band
}

/// One alarm as the screens show it, decoded from its stored row.
struct AlarmItem: Identifiable, Equatable, Sendable {
    let id: String
    let kind: String
    var label: String
    var enabled: Bool
    /// Nil for alarms without a time rule. The phone does not create those.
    var schedule: AlarmSchedule?
    var rhythm: RhythmSpec
    var channels: Set<AlarmChannel>

    init(row: AlarmRow) {
        id = row.id
        kind = row.kind
        label = row.label
        enabled = row.enabled
        schedule = row.schedule.flatMap { try? JSONDecoder().decode(AlarmSchedule.self, from: Data($0.utf8)) }
        rhythm = (try? RhythmSpec(jsonText: row.rhythm)) ?? .builtIn(.single)
        let names = (try? JSONDecoder().decode([String].self, from: Data(row.channels.utf8))) ?? []
        channels = Set(names.compactMap(AlarmChannel.init(rawValue:)))
    }

    /// Minutes after midnight, for ordering the list by time.
    var minuteOfDay: Int {
        guard let schedule else { return Int.max }
        return schedule.hour * 60 + schedule.minute
    }

    /// "Weekdays", "Every day", "Once", or the short day names, in week order.
    var repeatText: String {
        guard let schedule else { return "" }
        switch schedule.weekdays {
        case []: return "Once"
        case [1, 2, 3, 4, 5]: return "Weekdays"
        case [6, 7]: return "Weekends"
        case [1, 2, 3, 4, 5, 6, 7]: return "Every day"
        default: return schedule.weekdays.map(Weekdays.shortName).joined(separator: ", ")
        }
    }

    /// The time as a Date on today's calendar day, for `Text(_:style:)`, which formats it for the locale.
    var timeDate: Date {
        Calendar.current.date(
            bySettingHour: schedule?.hour ?? 0,
            minute: schedule?.minute ?? 0,
            second: 0,
            of: Date()
        ) ?? Date()
    }

    var rhythmName: String {
        switch rhythm {
        case let .builtIn(name): name.title
        case .custom: "Custom"
        }
    }

    /// The next time the rule fires after `now`, or nil for an alarm without a rule.
    func nextFire(after now: Date) -> Date? {
        schedule.flatMap { AlarmPlanner.nextOccurrence(of: $0, after: now) }
    }
}

extension BuiltInRhythm {
    /// The name the screens show. "SOS" keeps its capitals, which `capitalized` would lose.
    var title: String {
        switch self {
        case .sos: "SOS"
        default: rawValue.capitalized
        }
    }
}

/// Weekday names for ISO numbers (1 = Monday ... 7 = Sunday). Localized through Calendar.
enum Weekdays {
    static func shortName(_ iso: Int) -> String {
        Calendar.current.shortStandaloneWeekdaySymbols[iso % 7]
    }

    static func fullName(_ iso: Int) -> String {
        Calendar.current.standaloneWeekdaySymbols[iso % 7]
    }

    static func veryShortName(_ iso: Int) -> String {
        Calendar.current.veryShortStandaloneWeekdaySymbols[iso % 7]
    }
}

/// What the editor holds while it is open. Saved as a row by `AlarmCoordinator`.
struct AlarmDraft: Equatable, Sendable {
    /// Nil for an alarm that has not been saved yet.
    var id: String?
    var label: String
    var time: Date
    var weekdays: Set<Int>
    var rhythm: RhythmSpec
    var bandChannel: Bool
    var enabled: Bool

    /// A new alarm: 06:30, weekdays, the single buzz, phone only.
    static func new(now: Date = Date()) -> AlarmDraft {
        AlarmDraft(
            id: nil,
            label: "",
            time: Calendar.current.date(bySettingHour: 6, minute: 30, second: 0, of: now) ?? now,
            weekdays: [1, 2, 3, 4, 5],
            rhythm: .builtIn(.single),
            bandChannel: false,
            enabled: true
        )
    }

    init(id: String?, label: String, time: Date, weekdays: Set<Int>, rhythm: RhythmSpec, bandChannel: Bool, enabled: Bool) {
        self.id = id
        self.label = label
        self.time = time
        self.weekdays = weekdays
        self.rhythm = rhythm
        self.bandChannel = bandChannel
        self.enabled = enabled
    }

    init(item: AlarmItem) {
        id = item.id
        label = item.label
        time = Calendar.current.date(
            bySettingHour: item.schedule?.hour ?? 0,
            minute: item.schedule?.minute ?? 0,
            second: 0,
            of: Date()
        ) ?? Date()
        weekdays = Set(item.schedule?.weekdays ?? [])
        rhythm = item.rhythm
        bandChannel = item.channels.contains(.band)
        enabled = item.enabled
    }

    /// The schedule the draft describes. Nil only if the time cannot be read, which does not happen for a Date.
    var schedule: AlarmSchedule? {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        return AlarmSchedule(hour: parts.hour ?? 0, minute: parts.minute ?? 0, weekdays: Array(weekdays))
    }

    /// The row to store. A new alarm gets a UUIDv7 now, as the API contract asks for client-made rows.
    func row(existing: AlarmRow?, nowMs: Int64) throws -> AlarmRow {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let channels: [AlarmChannel] = bandChannel ? [.phone, .band] : [.phone]
        let channelJSON = try JSONEncoder().encode(channels.map(\.rawValue))
        let scheduleJSON = try schedule.map { try JSONEncoder().encode($0) }
        return AlarmRow(
            id: existing?.id ?? UUIDv7.make(unixMs: nowMs).uuidString.lowercased(),
            kind: existing?.kind ?? "scheduled",
            label: trimmed.isEmpty ? "Alarm" : trimmed,
            schedule: scheduleJSON.map { String(decoding: $0, as: UTF8.self) },
            rhythm: try rhythm.jsonText(),
            channels: String(decoding: channelJSON, as: UTF8.self),
            enabled: enabled,
            version: existing?.version ?? 0,
            updatedAt: nowMs,
            deletedAt: nil,
            dirty: false
        )
    }
}
