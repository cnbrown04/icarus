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
    private(set) var status = SyncStatus(phase: .notPaired)
    private(set) var isRunning = false
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
        isRunning = false
        await refresh()
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
