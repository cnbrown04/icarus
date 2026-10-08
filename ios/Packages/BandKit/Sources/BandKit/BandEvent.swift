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
    case battery(Int)
}
