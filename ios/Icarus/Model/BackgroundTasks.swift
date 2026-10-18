import BackgroundTasks
import Foundation
import Synchronization

/// BGTaskScheduler work (PLAN.md 11.2). Both identifiers are in Info.plist and are registered before launch
/// finishes. Registration happens in `IcarusApp.init`.
enum BackgroundTasks {
    static let refreshIdentifier = "com.cnbrown04.icarus.sync"
    static let maintenanceIdentifier = "com.cnbrown04.icarus.maintenance"
    /// The earliest a refresh may start. The system decides the actual time.
    static let refreshDelay: TimeInterval = 15 * 60

    @MainActor
    static func register(_ environment: AppEnvironment) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshIdentifier, using: nil) { task in
            let box = TaskBox(value: task)
            run(box) { await environment.runBackgroundRefresh() }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: maintenanceIdentifier, using: nil) { task in
            let box = TaskBox(value: task)
            run(box) { await environment.runMaintenance() }
        }
    }

    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: refreshDelay)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Backlog and retention work waits for network and external power (PLAN.md 11.2).
    static func scheduleMaintenance() {
        let request = BGProcessingTaskRequest(identifier: maintenanceIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = true
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Runs the work once and reports completion, whichever of the work or the system's expiry comes first.
    private static func run(_ box: TaskBox, work: @escaping @Sendable () async -> Void) {
        let finished = Mutex(false)
        let complete: @Sendable (Bool) -> Void = { success in
            let first = finished.withLock { done -> Bool in
                if done { return false }
                done = true
                return true
            }
            if first { box.value.setTaskCompleted(success: success) }
        }
        box.value.expirationHandler = { complete(false) }
        Task {
            await work()
            complete(true)
        }
    }
}

/// BGTask is not Sendable. It is handed to exactly one completion path, guarded by `run`.
private struct TaskBox: @unchecked Sendable {
    let value: BGTask
}
