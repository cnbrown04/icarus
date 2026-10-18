import Foundation
import GRDB
import Observation
import Store
import SyncKit
import UIKit

/// What the Sync screen reads from the store, loaded in one transaction.
struct SyncScreenData: Sendable {
    let batches: [SyncBatchRow]
    let quarantined: [SyncBatchRow]
    let pendingRows: Int

    static func load(_ db: Database) throws -> SyncScreenData {
        SyncScreenData(
            batches: try db.syncBatches(limit: 50),
            quarantined: try db.syncBatches(status: "rejected", limit: 50),
            pendingRows: try SyncSnapshot.load(db).pendingRows
        )
    }
}

/// Why pairing failed. The message is shown under the form (PLAN.md 15.1 rule 8).
enum PairingFailure: Error, Equatable {
    case address
    case code
    case rejected
    case unreachable

    var message: String {
        switch self {
        case .address: "Enter an https address, such as icarus.example.com."
        case .code: "Enter the 8-character code from the website."
        case .rejected: "That code is invalid or expired. Create a new code on the website."
        case .unreachable: "Could not reach the server. Check the address and try again."
        }
    }
}

/// App-side face of SyncKit: the status the screens show, and the calls that pair, sync and unpair.
@MainActor
@Observable
final class SyncController {
    /// The PLAN.md 11.5 toast text, shown when the server rejected a local alarm edit with 409.
    static let alarmConflictMessage = "Alarm changed on the web; your edit wasn't saved"

    private(set) var status = SyncStatus(phase: .notPaired)
    private(set) var isRunning = false
    /// True after a 409 on an alarm edit, until the toast is dismissed.
    private(set) var alarmConflictNotice = false
    /// The device's APNs token, once iOS has issued one (PLAN.md 12.5). Sent to the server when paired.
    private(set) var pushToken: String?
    @ObservationIgnored private var sentPushToken: String?
    /// False while the app is in the background. Background uploads are queued only then (PLAN.md 11.2).
    var isForeground = true

    let engine: SyncEngine
    let uploader: BackgroundUploader?

    init(engine: SyncEngine, uploader: BackgroundUploader?) {
        self.engine = engine
        self.uploader = uploader
    }

    func refresh() async {
        status = await engine.status()
    }

    /// One sync pass. A call made while a pass runs joins it (SyncEngine.run).
    func runNow() async {
        guard !isRunning else { return }
        isRunning = true
        _ = await engine.run()
        if await engine.takeAlarmConflicts() > 0 {
            alarmConflictNotice = true
        }
        isRunning = false
        await sendPushTokenIfNeeded()
        await refresh()
    }

    /// Sends the alarm edits now, for the editor's Save and the alarm actions.
    func pushAlarmEdits() async {
        let result = await engine.pushAlarmEdits()
        if result.conflicts > 0 {
            alarmConflictNotice = true
        }
        await refresh()
    }

    func dismissAlarmConflictNotice() {
        alarmConflictNotice = false
    }

    /// Records the token iOS issued. It is sent when the device is paired, and again when the token changes.
    func receivePushToken(_ hex: String) async {
        pushToken = hex
        await sendPushTokenIfNeeded()
    }

    private func sendPushTokenIfNeeded() async {
        guard let token = pushToken, token != sentPushToken, status.phase != .notPaired else { return }
        do {
            try await engine.sendPushToken(token, environment: .current)
            sentPushToken = token
        } catch {
            // Not paired yet, or offline. The next sync run tries again.
        }
    }

    func pair(server: URL, code: String) async throws {
        do {
            try await engine.pair(serverURL: server, code: code, device: .current)
        } catch APIError.http(let status, let problem, _) where status == 400 || problem?.slug == "pairing-code-invalid" {
            throw PairingFailure.rejected
        } catch {
            throw PairingFailure.unreachable
        }
        await refresh()
        await runNow()
    }

    func unpair() async {
        try? await engine.unpair()
        await refresh()
    }

    func enqueueBackgroundUploadIfNeeded() async {
        guard !isForeground, let uploader else { return }
        _ = await engine.enqueueBackgroundUpload(uploader)
        await refresh()
    }
}

extension PushEnvironment {
    /// Debug builds run from Xcode and get sandbox tokens. TestFlight and App Store builds get production tokens.
    static var current: PushEnvironment {
        #if DEBUG
        .sandbox
        #else
        .production
        #endif
    }
}

extension DeviceInfo {
    /// The name is generic on purpose, so the device's own name (often a personal name) never leaves the phone.
    @MainActor
    static var current: DeviceInfo {
        var system = utsname()
        uname(&system)
        let model = withUnsafePointer(to: system.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: system.machine)) {
                String(cString: $0)
            }
        }
        return DeviceInfo(
            name: "iPhone",
            model: model,
            osVersion: UIDevice.current.systemVersion,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        )
    }
}
