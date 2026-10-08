import Foundation

/// Whether the app may schedule system alarms.
public enum AlarmAuthorization: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
}

/// What the phone needs to ring one alarm: its id, the text shown when it rings, and its rule.
public struct ScheduledAlarm: Equatable, Sendable {
    public let id: UUID
    public let label: String
    public let schedule: AlarmSchedule
    /// The next time the rule fires. A one-off alarm (no weekdays) is scheduled for this date.
    public let nextFire: Date

    public init(id: UUID, label: String, schedule: AlarmSchedule, nextFire: Date) {
        self.id = id
        self.label = label
        self.schedule = schedule
        self.nextFire = nextFire
    }
}

/// Schedules phone alarms by id. `AlarmKitScheduler` is the real one. `InMemoryAlarmScheduler` records calls for tests
/// and UI tests, where no system prompt may appear.
public protocol AlarmScheduling: Sendable {
    func authorization() async -> AlarmAuthorization
    func requestAuthorization() async throws -> AlarmAuthorization
    /// Replaces any alarm with the same id.
    func schedule(_ alarm: ScheduledAlarm) async throws
    /// Removes the alarm with this id. Does nothing when there is none.
    func cancel(id: UUID) async throws
}

/// Keeps scheduled alarms in memory and touches no system service.
public actor InMemoryAlarmScheduler: AlarmScheduling {
    public private(set) var scheduled: [UUID: ScheduledAlarm] = [:]
    private let grant: AlarmAuthorization

    public init(authorization: AlarmAuthorization = .authorized) {
        grant = authorization
    }

    public func authorization() async -> AlarmAuthorization {
        grant
    }

    public func requestAuthorization() async throws -> AlarmAuthorization {
        grant
    }

    public func schedule(_ alarm: ScheduledAlarm) async throws {
        scheduled[alarm.id] = alarm
    }

    public func cancel(id: UUID) async throws {
        scheduled[id] = nil
    }
}
