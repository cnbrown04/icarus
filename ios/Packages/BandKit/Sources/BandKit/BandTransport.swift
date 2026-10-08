import Foundation

/// Source of band events. Implementations: CoreBluetoothTransport, FixtureTransport, SyntheticTransport.
public protocol BandTransport: Sendable {
    var events: AsyncStream<BandEvent> { get }
    func start() async
    func stop() async
    /// Connects to a band chosen from a `.discovered` event. Transports without scanning ignore it.
    func pair(_ id: UUID) async
    /// Clears the remembered band and rescans. Transports without a remembered band ignore it.
    func forget() async

    // Tier B (PLAN.md 5.3.6, 7.2, 9.2, 9.5). Off by default. Fixture and synthetic transports only record these calls.

    /// Turns Tier B on or off. Off stops all custom-service traffic (PLAN.md 19 Phase 6).
    func setTierBEnabled(_ enabled: Bool) async
    /// Plays a rhythm on the band, replacing any rhythm already running. Does nothing unless Tier B is ready.
    func runRhythm(_ rhythm: Rhythm) async
    /// Cancels a running rhythm, or sends STOP_HAPTICS when none is running.
    func stopHaptics() async
    /// Arms the band alarm for the next due occurrence, in UTC. nil sends nothing: no disarm command is documented (PLAN.md 5.3.4).
    func armBandAlarm(at: Date?) async
}

/// A Tier B request, recorded by transports that cannot send it.
public enum TierBRequest: Sendable, Equatable {
    case setEnabled(Bool)
    case runRhythm(Rhythm)
    case stopHaptics
    case armAlarm(Date?)
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
