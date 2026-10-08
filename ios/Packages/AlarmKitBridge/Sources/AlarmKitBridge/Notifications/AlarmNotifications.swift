import Foundation

/// Names shared by the alert payloads the server sends and the category the app registers (PLAN.md 9.1, 12.5).
public enum AlarmNotificationIdentifiers {
    public static let category = "ICARUS_ALARM"
    public static let snoozeAction = "ICARUS_SNOOZE"
    public static let dismissAction = "ICARUS_DISMISS"
    /// Snooze repeats the alert after five minutes (PLAN.md 12.5).
    public static let snoozeSeconds: TimeInterval = 5 * 60
}

#if canImport(UserNotifications)
import UserNotifications

/// Local time-sensitive alerts and the ICARUS_ALARM category (PLAN.md 9.1 relay and test alerts).
public struct AlarmNotifier: Sendable {
    public init() {}

    /// Registers the category with its Snooze and Dismiss actions. Safe to call on every launch.
    public func registerCategory() {
        let snooze = UNNotificationAction(
            identifier: AlarmNotificationIdentifiers.snoozeAction,
            title: "Snooze 5 min",
            options: []
        )
        let dismiss = UNNotificationAction(
            identifier: AlarmNotificationIdentifiers.dismissAction,
            title: "Dismiss",
            options: [.destructive]
        )
        let category = UNNotificationCategory(
            identifier: AlarmNotificationIdentifiers.category,
            actions: [snooze, dismiss],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    public func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// A time-sensitive alert now, or after `delay` seconds.
    public func post(title: String, body: String, after delay: TimeInterval = 0) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = AlarmNotificationIdentifiers.category
        content.interruptionLevel = .timeSensitive
        let trigger: UNNotificationTrigger? = delay > 0
            ? UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
            : nil
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        try await UNUserNotificationCenter.current().add(request)
    }
}
#endif
