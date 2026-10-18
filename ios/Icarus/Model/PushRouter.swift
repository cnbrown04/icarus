import AlarmKitBridge
import Foundation
import SyncKit
import UIKit
import UserNotifications

/// Routes alarm pushes and alarm notification actions (PLAN.md 9.3, 12.5). A dispatch plays on the band when Tier B is
/// ready, and is acked with what the phone and the band did. Each dispatch plays once per session, so the alert and the
/// background push for the same alarm do not buzz the band twice.
@MainActor
final class PushRouter {
    static let shared = PushRouter()

    private weak var sync: SyncController?
    private weak var band: LiveState?
    private var played: Set<String> = []

    func attach(sync: SyncController, band: LiveState) {
        self.sync = sync
        self.band = band
    }

    /// The APNs token iOS issued at launch.
    func receiveToken(_ hex: String) {
        Task { await sync?.receivePushToken(hex) }
    }

    /// A silent push. `config_changed` means the server's config moved, so pull it (PLAN.md 12.5). Any other silent
    /// push is an alarm dispatch.
    func backgroundPush(configChanged: Bool) async -> UIBackgroundFetchResult {
        if configChanged {
            await sync?.runNow()
            return .newData
        }
        return await deliverPendingDispatches() ? .newData : .noData
    }

    /// The alert arrived while the app is open. Delivering the dispatch here is what makes the phone ack "shown".
    func alertShown() async {
        _ = await deliverPendingDispatches()
    }

    /// Snooze repeats the same alert after five minutes (PLAN.md 12.5). Dismiss needs no work.
    func snooze(title: String, body: String) async {
        try? await AlarmNotifier().post(title: title, body: body, after: AlarmNotificationIdentifiers.snoozeSeconds)
    }

    /// Plays and acks every dispatch the server still lists as unacked. Returns true when there was one.
    private func deliverPendingDispatches() async -> Bool {
        guard let sync, let dispatches = try? await sync.engine.pendingDispatches() else { return false }
        var handled = false
        for dispatch in dispatches where !played.contains(dispatch.id) {
            played.insert(dispatch.id)
            handled = true
            let bandAck = await playOnBand(dispatch.rhythmJSON)
            do {
                try await sync.engine.ackDispatch(id: dispatch.id, phone: .shown, band: bandAck)
            } catch {
                // Not acked, so the server sends it again. Forget it here so the next delivery can ack it.
                played.remove(dispatch.id)
            }
        }
        return handled
    }

    private func playOnBand(_ rhythmJSON: String) async -> BandAck {
        guard BandChannel.isEnabled, let band else { return .disabled }
        guard band.state == .streaming else { return .notConnected }
        guard band.tierBState == .ready,
              let spec = try? RhythmSpec(jsonText: rhythmJSON),
              let rhythm = try? spec.rhythm()
        else { return .failed }
        await band.runRhythm(rhythm)
        return .ok
    }
}

/// Receives alarm alerts and their actions. UserNotifications calls these off the main actor, so they copy what they
/// need and hand the work to `PushRouter` on the main actor.
final class AlarmNotificationRouter: NSObject, @preconcurrency UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
        Task { @MainActor in
            await PushRouter.shared.alertShown()
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        let title = response.notification.request.content.title
        let body = response.notification.request.content.body
        completionHandler()
        guard action == AlarmNotificationIdentifiers.snoozeAction else { return }
        Task { @MainActor in
            await PushRouter.shared.snooze(title: title, body: body)
        }
    }
}
