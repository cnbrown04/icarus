import BandProtocol
import Foundation

/// Events emitted by a band transport. Phase 0 covers the Tier A heart-rate path only.
public enum BandEvent: Sendable, Equatable {
    case connected
    case disconnected
    case hr(HeartRateMeasurement, receivedAt: Date)
    case battery(Int)
}
