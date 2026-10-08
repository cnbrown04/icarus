import AlarmKitBridge
import SyncKit
import UIKit
import UserNotifications

/// The UIKit hooks SwiftUI does not cover: the background URLSession, the APNs token, silent pushes and alarm
/// notifications (PLAN.md 11.2, 12.5). Each one hands its work to `PushRouter` on the main actor.
final class AppDelegate: NSObject, UIApplicationDelegate {
    private let notificationRouter = AlarmNotificationRouter()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().delegate = notificationRouter
        AlarmNotifier().registerCategory()
        // UI tests run with no push token. Registering would only add a system call that does nothing there.
        if !LaunchConfig.current.isUITest {
            application.registerForRemoteNotifications()
        }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in
            PushRouter.shared.receiveToken(hex)
        }
    }

    /// Silent pushes wake the app for an alarm dispatch or a config change (PLAN.md 12.5). The payload is read here,
    /// and only the Bool crosses to the main actor.
    // [Unverified] The async form of this delegate method is the one the iOS 26 SDK offers.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        let configChanged = (userInfo["config_changed"] as? Bool) == true
        return await PushRouter.shared.backgroundPush(configChanged: configChanged)
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackgroundUploader.identifier else {
            completionHandler()
            return
        }
        BackgroundUploader.handleEvents(completion: completionHandler)
    }
}
