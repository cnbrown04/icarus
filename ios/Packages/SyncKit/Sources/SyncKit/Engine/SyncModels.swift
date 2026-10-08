import Foundation

/// What the Sync screen shows (PLAN.md 14 row 16).
public struct SyncStatus: Equatable, Sendable {
    public var phase: SyncPhase
    public var lastSuccessAt: Date?
    /// True when the last server time was more than 2 min from the device clock (PLAN.md 11.5).
    public var clockSkewWarning: Bool
    public var quarantinedBatches: Int
    /// The paired server's host, for Settings. Nil when not paired.
    public var serverHost: String?

    public init(
        phase: SyncPhase,
        lastSuccessAt: Date? = nil,
        clockSkewWarning: Bool = false,
        quarantinedBatches: Int = 0,
        serverHost: String? = nil
    ) {
        self.phase = phase
        self.lastSuccessAt = lastSuccessAt
        self.clockSkewWarning = clockSkewWarning
        self.quarantinedBatches = quarantinedBatches
        self.serverHost = serverHost
    }
}

public enum SyncPhase: Equatable, Sendable {
    case notPaired
    case idle
    case syncing
    /// Waiting after a network, 5xx or 429 failure (PLAN.md 11.3).
    case retrying(at: Date)
    /// The server rejected the device token (401). The user must pair again (PLAN.md 11.6).
    case needsRepair
}

/// Outcome of one `SyncEngine.run()`.
public enum SyncRunResult: Equatable, Sendable {
    case synced
    case retry(at: Date)
    case needsRepair
    case notPaired
}

/// Device identity sent when pairing. The name is generic on purpose, so no personal name leaves the phone.
public struct DeviceInfo: Equatable, Sendable {
    public let name: String
    public let model: String
    public let osVersion: String
    public let appVersion: String

    public init(name: String, model: String, osVersion: String, appVersion: String) {
        self.name = name
        self.model = model
        self.osVersion = osVersion
        self.appVersion = appVersion
    }
}

/// Injected time and randomness, so backoff and skew checks are exact in tests.
public struct SyncClock: Sendable {
    public var now: @Sendable () -> Date
    /// A value in 0...upper. Full jitter uses it as-is.
    public var uniform: @Sendable (TimeInterval) -> TimeInterval

    public init(now: @escaping @Sendable () -> Date, uniform: @escaping @Sendable (TimeInterval) -> TimeInterval) {
        self.now = now
        self.uniform = uniform
    }

    public static let system = SyncClock(
        now: { Date() },
        uniform: { upper in Double.random(in: 0...upper) }
    )

    func nowMs() -> Int64 {
        Int64((now().timeIntervalSince1970 * 1000).rounded(.down))
    }
}

/// Foreground sync interval (PLAN.md 11.2). Stored in UserDefaults under `storageKey`.
public enum SyncInterval: Int, CaseIterable, Sendable {
    case oneMinute = 1
    case fiveMinutes = 5
    case fifteenMinutes = 15
    case hour = 60

    public static let defaultValue: SyncInterval = .fiveMinutes
    public static let storageKey = "sync.intervalMinutes"

    public var seconds: TimeInterval {
        TimeInterval(rawValue * 60)
    }

    public var label: String {
        rawValue < 60 ? "\(rawValue) min" : "1 h"
    }

    public static func stored(in defaults: UserDefaults = .standard) -> SyncInterval {
        SyncInterval(rawValue: defaults.integer(forKey: storageKey)) ?? defaultValue
    }
}

/// Exponential backoff with full jitter, 5 s doubling to a 10 min cap (PLAN.md 11.3).
public enum Backoff {
    public static let base: TimeInterval = 5
    public static let cap: TimeInterval = 600

    /// Full jitter: uniform in 0...min(cap, base * 2^attempt). A server Retry-After is a floor.
    public static func delay(
        attempt: Int,
        retryAfter: TimeInterval?,
        uniform: (TimeInterval) -> TimeInterval
    ) -> TimeInterval {
        let ceiling = min(cap, base * Double(1 << min(max(attempt, 0), 20)))
        let jittered = uniform(ceiling)
        guard let retryAfter else { return jittered }
        return max(retryAfter, jittered)
    }
}
