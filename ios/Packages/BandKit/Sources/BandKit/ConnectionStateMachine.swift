import Foundation

/// Where the band link is in its lifecycle (PLAN.md §7.2).
public enum ConnectionState: Sendable, Equatable {
    case idle
    case scanning
    case connecting
    case discovering
    case subscribing
    case streaming
    /// Waiting before the next attempt. `attempt` counts consecutive failures, starting at 1.
    case backoff(attempt: Int)
}

/// Things that happen to the link: user actions, CoreBluetooth callbacks and timers.
public enum ConnectionInput: Sendable, Equatable {
    case start
    /// Ends the session. The remembered band is kept.
    case stop
    /// Ends the session and clears the remembered band.
    case forget
    case peripheralDiscovered(UUID)
    /// The user picked a band from the scan list.
    case pairRequested(UUID)
    /// The remembered band could not be retrieved, so scanning must find it again.
    case rememberedPeripheralUnavailable
    case connected
    case connectFailed
    case servicesDiscovered
    /// The Heart Rate service or characteristic is missing, or notify could not be enabled.
    case heartRateUnavailable
    case subscribed
    case disconnected
    case retryTimerFired
}

/// Work the transport must perform. The machine never touches CoreBluetooth itself.
public enum ConnectionEffect: Sendable, Equatable {
    case startScan
    case stopScan
    case connect(UUID)
    /// Cancels a connection attempt or tears down an established link.
    case cancelConnection(UUID)
    case discoverServices
    case subscribe
    case scheduleRetry(after: TimeInterval)
    case cancelRetry
    case rememberPeripheral(UUID)
    case forgetPeripheral
}

/// Pure connection logic: inputs in, state and effects out. Fully testable on Linux.
///
/// Remembered band: once a band streams, its identifier is handed to the transport to persist.
/// On start, a remembered band is connected to directly, without scanning.
/// Backoff: 1, 2, 5, 15 and 30 s, then 30 s for every further attempt. A successful subscribe resets it.
public struct ConnectionStateMachine: Sendable, Equatable {
    public static let backoffSchedule: [TimeInterval] = [1, 2, 5, 15, 30]

    public private(set) var state: ConnectionState = .idle
    public private(set) var rememberedID: UUID?
    /// The peripheral being scanned for, connected to or streamed from.
    public private(set) var targetID: UUID?
    private var failures = 0

    public init(rememberedID: UUID? = nil) {
        self.rememberedID = rememberedID
    }

    public static func backoffDelay(forAttempt attempt: Int) -> TimeInterval {
        let index = min(max(attempt, 1), backoffSchedule.count) - 1
        return backoffSchedule[index]
    }

    public mutating func handle(_ input: ConnectionInput) -> [ConnectionEffect] {
        switch input {
        case .start:
            return start()
        case .stop:
            return endSession()
        case .forget:
            var effects = endSession()
            rememberedID = nil
            effects.append(.forgetPeripheral)
            return effects
        case let .peripheralDiscovered(id):
            return peripheralDiscovered(id)
        case let .pairRequested(id):
            return pairRequested(id)
        case .rememberedPeripheralUnavailable:
            guard state == .connecting else { return [] }
            state = .scanning
            targetID = nil
            return [.startScan]
        case .connected:
            guard state == .connecting else { return [] }
            state = .discovering
            return [.discoverServices]
        case .servicesDiscovered:
            guard state == .discovering else { return [] }
            state = .subscribing
            return [.subscribe]
        case .heartRateUnavailable:
            guard state == .discovering || state == .subscribing else { return [] }
            return failure(cancelConnection: true)
        case .connectFailed:
            guard state == .connecting else { return [] }
            return failure(cancelConnection: false)
        case .disconnected:
            switch state {
            case .connecting, .discovering, .subscribing, .streaming:
                return failure(cancelConnection: false)
            default:
                return []
            }
        case .subscribed:
            guard state == .subscribing else { return [] }
            state = .streaming
            failures = 0
            guard let target = targetID, target != rememberedID else { return [] }
            rememberedID = target
            return [.rememberPeripheral(target)]
        case .retryTimerFired:
            guard case .backoff = state else { return [] }
            if let target = targetID {
                state = .connecting
                return [.connect(target)]
            }
            state = .scanning
            return [.startScan]
        }
    }

    private mutating func start() -> [ConnectionEffect] {
        guard state == .idle else { return [] }
        if let remembered = rememberedID {
            targetID = remembered
            state = .connecting
            return [.connect(remembered)]
        }
        state = .scanning
        return [.startScan]
    }

    private mutating func peripheralDiscovered(_ id: UUID) -> [ConnectionEffect] {
        // Only the remembered band is connected automatically. Other bands wait for the user.
        guard state == .scanning, id == rememberedID else { return [] }
        targetID = id
        state = .connecting
        return [.stopScan, .connect(id)]
    }

    private mutating func pairRequested(_ id: UUID) -> [ConnectionEffect] {
        guard state != .idle else { return [] }
        let linked = state == .connecting || state == .discovering || state == .subscribing || state == .streaming
        if linked, targetID == id { return [] }

        var effects: [ConnectionEffect] = []
        switch state {
        case .scanning:
            effects.append(.stopScan)
        case .backoff:
            effects.append(.cancelRetry)
        default:
            break
        }
        if linked, let previous = targetID {
            effects.append(.cancelConnection(previous))
        }
        failures = 0
        targetID = id
        state = .connecting
        effects.append(.connect(id))
        return effects
    }

    /// Stops the session but keeps the remembered band. Used by stop, forget and Bluetooth power-off.
    private mutating func endSession() -> [ConnectionEffect] {
        var effects: [ConnectionEffect] = []
        switch state {
        case .idle:
            break
        case .scanning:
            effects.append(.stopScan)
        case .backoff:
            effects.append(.cancelRetry)
        case .connecting, .discovering, .subscribing, .streaming:
            if let target = targetID {
                effects.append(.cancelConnection(target))
            }
        }
        state = .idle
        targetID = nil
        failures = 0
        return effects
    }

    private mutating func failure(cancelConnection: Bool) -> [ConnectionEffect] {
        failures += 1
        var effects: [ConnectionEffect] = []
        if cancelConnection, let target = targetID {
            effects.append(.cancelConnection(target))
        }
        state = .backoff(attempt: failures)
        effects.append(.scheduleRetry(after: Self.backoffDelay(forAttempt: failures)))
        return effects
    }
}
