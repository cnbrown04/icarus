#if canImport(AlarmKit)
import AlarmKit
import Foundation
import SwiftUI

/// Phone alarms through AlarmKit (iOS 26, PLAN.md 9.1). Scheduled alarms are always armed here, so a band failure
/// never causes a missed alarm (PLAN.md 6.5). Every API below is unverified until the macOS build confirms it.
public struct AlarmKitScheduler: AlarmScheduling {
    public init() {}

    public func authorization() async -> AlarmAuthorization {
        // [Unverified] AlarmManager.shared.authorizationState, its cases.
        switch AlarmManager.shared.authorizationState {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        @unknown default: .denied
        }
    }

    public func requestAuthorization() async throws -> AlarmAuthorization {
        // [Unverified] AlarmManager.shared.requestAuthorization() returns the new state.
        _ = try await AlarmManager.shared.requestAuthorization()
        return await authorization()
    }

    public func schedule(_ alarm: ScheduledAlarm) async throws {
        // [Unverified] Alarm.Schedule.fixed / .relative, Relative.Time, Recurrence .weekly, and the alarm configuration
        // initialiser. Only the labelled parameters used here are assumed.
        let attributes = AlarmAttributes(
            presentation: AlarmPresentation(
                alert: AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: alarm.label))
            ),
            metadata: IcarusAlarmMetadata(),
            tintColor: .pink
        )
        let configuration = AlarmManager.AlarmConfiguration<IcarusAlarmMetadata>.alarm(
            schedule: Self.schedule(for: alarm),
            attributes: attributes
        )
        try await AlarmManager.shared.schedule(id: alarm.id, configuration: configuration)
    }

    public func cancel(id: UUID) async throws {
        // [Unverified] Whether cancel(id:) is synchronous. Written as a throwing call.
        try AlarmManager.shared.cancel(id: id)
    }

    /// A repeating rule uses the system's weekly recurrence, so DST and timezone changes are handled by AlarmKit.
    /// A one-off uses the next fire date.
    static func schedule(for alarm: ScheduledAlarm) -> Alarm.Schedule {
        guard !alarm.schedule.weekdays.isEmpty else { return .fixed(alarm.nextFire) }
        let time = Alarm.Schedule.Relative.Time(hour: alarm.schedule.hour, minute: alarm.schedule.minute)
        let days = alarm.schedule.weekdays.compactMap(weekday)
        return .relative(Alarm.Schedule.Relative(time: time, repeats: .weekly(days)))
    }

    /// ISO 1...7 to `Locale.Weekday`.
    static func weekday(_ iso: Int) -> Locale.Weekday? {
        switch iso {
        case 1: .monday
        case 2: .tuesday
        case 3: .wednesday
        case 4: .thursday
        case 5: .friday
        case 6: .saturday
        case 7: .sunday
        default: nil
        }
    }
}

/// What AlarmKit keeps with each alarm. Icarus stores nothing extra.
public struct IcarusAlarmMetadata: AlarmMetadata {
    public init() {}
}
#endif
