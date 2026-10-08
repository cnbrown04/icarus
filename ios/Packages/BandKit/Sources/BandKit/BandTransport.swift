import Foundation

/// Source of band events. Implementations: FixtureTransport, SyntheticTransport.
///
/// TODO(PLAN.md §7.2): add `send(_ command: SafeCommand) async throws` for Tier B (Phase 6).
public protocol BandTransport: Sendable {
    var events: AsyncStream<BandEvent> { get }
    func start() async
    func stop() async
}

/// Paces replay and synthetic output. Tests inject a recording clock so nothing sleeps.
public protocol ReplayClock: Sendable {
    func sleep(seconds: Double) async throws
}

public struct RealtimeClock: ReplayClock {
    public init() {}

    public func sleep(seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}

// TODO(PLAN.md §7.2): CoreBluetoothTransport, the real device path (Phase 1).
