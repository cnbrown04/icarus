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

/// One EVENT (0x30) frame as received: its id (the frame's `cmd` byte), the decoded kind, the payload bytes
/// and when it arrived.
public struct BandEventRecord: Sendable, Equatable {
    public let id: UInt8
    public let kind: BandEventKind
    public let payload: [UInt8]
    public let at: Date

    public init(id: UInt8, payload: [UInt8], at: Date) {
        self.id = id
        self.kind = BandEventKind(id: id)
        self.payload = payload
        self.at = at
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
    /// An EVENT (0x30) frame from the band, such as wrist on/off or a double tap (PLAN.md 5.3.4), with its
    /// payload bytes so unnamed ids can be identified later.
    case bandEvent(BandEventRecord)
    /// Best-effort identity strings decoded from the GET_HELLO reply, emitted once per connection
    /// after the handshake completes (PLAN.md 5.3.4). Fields may all be nil when the reply holds
    /// nothing confident.
    case bandInfo(BandInfo)
    /// The decoded records of one completed history offload drain, emitted exactly once per drain
    /// (PLAN.md 5.3.4). The records are not kept by the transport; the consumer persists them.
    /// Drained batches also flush as they are acked, so this is normally only the last partial batch.
    case historical([HistoricalRecord])
    /// Live history-offload progress: emitted on drain start, throttled while batches are acked,
    /// and once at drain end with the stop reason (PLAN.md 5.3.4). Cheap enough for the UI to
    /// observe every band connection and periodic drain without per-record work.
    case drainProgress(DrainProgress)
    /// A human-readable reason the Tier B custom-service setup or handshake failed. Emitted just
    /// before `.tierB(.unavailable)`. The Device screen shows it while the state is `.unavailable`.
    case tierBFailure(String)
    /// A decoded frame the controller did not otherwise act on — today the REALTIME_RAW_DATA
    /// (0x2B) accel/PPG flood (~1.9 KB/s), which nothing parses. The raw-data viewer shows its
    /// header and hex; consumers format hex lazily, because the flood never stops while streaming.
    case rawFrame(Frame, at: Date)
    /// Charging state from the strap's charging-on (event 7) or charging-off (event 8) event (whoop-parity §3.7).
    case charging(Bool)
    /// The LINK_VALID keep-alive (cmd 1): when the last one was written and how many have failed in a row.
    /// `sentAt` is nil until the first successful write on this link. [Unverified] cadence and behaviour.
    case linkKeepAlive(sentAt: Date?, consecutiveFailures: Int)
    /// Decoded lines of one CONSOLE_LOGS (type 50) frame, already stripped of non-printables (whoop-parity §3.5).
    case consoleLines([String], at: Date)
}
