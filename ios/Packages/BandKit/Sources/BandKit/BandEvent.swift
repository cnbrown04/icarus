import BandProtocol
import Foundation

/// A band seen during a scan, or the band we are connected to.
public struct DiscoveredBand: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String?
    /// Received signal strength in dBm.
    public let rssi: Int

    public init(id: UUID, name: String?, rssi: Int) {
        self.id = id
        self.name = name
        self.rssi = rssi
    }
}

/// Events emitted by a band transport.
public enum BandEvent: Sendable, Equatable {
    case state(ConnectionState)
    case discovered(DiscoveredBand)
    /// The band to reconnect to on the next launch, or nil after Forget.
    case remembered(UUID?)
    /// A raw notification from a recorded characteristic, before parsing. Feeds FrameLog.
    case raw(char: String, bytes: [UInt8], at: Date)
    case hr(HeartRateMeasurement, receivedAt: Date)
    /// Battery percent. From the standard 0x2A19 read, or from Tier B GET_BATTERY_LEVEL (PLAN.md 5.3.4).
    case battery(Int)
    /// Tier B link state changed (PLAN.md 5.3.6, 7.2).
    case tierB(TierBState)
    /// An EVENT (0x30) frame from the band, such as wrist on/off or a double tap (PLAN.md 5.3.4).
    case bandEvent(BandEventKind)
    /// Best-effort identity strings decoded from the GET_HELLO reply, emitted once per connection
    /// after the handshake completes (PLAN.md 5.3.4). Fields may all be nil when the reply holds
    /// nothing confident.
    case bandInfo(BandInfo)
    /// The decoded records of one completed history offload drain, emitted exactly once per drain
    /// (PLAN.md 5.3.4). The records are not kept by the transport; the consumer persists them.
    case historical([HistoricalRecord])
    /// A human-readable reason the Tier B custom-service setup or handshake failed. Emitted just
    /// before `.tierB(.unavailable)`. The Device screen shows it while the state is `.unavailable`.
    case tierBFailure(String)
}
