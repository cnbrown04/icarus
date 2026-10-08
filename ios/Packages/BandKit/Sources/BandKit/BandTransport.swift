import Foundation

/// Source of band events. Implementations: CoreBluetoothTransport, FixtureTransport, SyntheticTransport.
///
/// TODO(PLAN.md §7.2): Tier B `send(_ command: SafeCommand) async throws` (Phase 6). Not part of Tier A.
public protocol BandTransport: Sendable {
    var events: AsyncStream<BandEvent> { get }
    func start() async
    func stop() async
    /// Connects to a band chosen from a `.discovered` event. Transports without scanning ignore it.
    func pair(_ id: UUID) async
    /// Clears the remembered band and rescans. Transports without a remembered band ignore it.
    func forget() async
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
