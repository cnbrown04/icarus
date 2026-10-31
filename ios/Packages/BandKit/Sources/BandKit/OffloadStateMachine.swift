import BandProtocol
import Foundation

/// Pure state machine for the strap's history offload (PLAN.md 5.3.4, cmds 22/23). No CoreBluetooth.
///
/// The strap streams HISTORICAL_DATA (type 47) records in batches, closes each batch with a
/// METADATA (type 49) frame carrying an 8-byte token, and replays the batch until the app echoes
/// that token with HISTORICAL_DATA_RESULT (cmd 23) as a confirmed write. The drain ends when the
/// store is caught up, the link dies, or the strap goes quiet.
///
/// Time never enters this type directly: the injected `TierBClock` (the same protocol
/// `TierBController` uses, so one clock serves both) stamps every event and produces the
/// `quietDeadline`, which the driver is expected to watch and turn into a `.quietElapsed` event.
///
/// One `OffloadStateMachine` value is owned and mutated by the caller; it is a struct, so the whole
/// state is inspectable and copyable in tests.
public struct OffloadStateMachine {
    /// Quiet timeout after the last record or metadata (PLAN.md 5.3.4 drain rules).
    public static let quietTimeout: TimeInterval = 8
    /// A record this close to the clock's now means the store reached the live edge; continuing
    /// would re-offload the newest second forever. Assumes the band RTC is kept correct by
    /// SET_CLOCK (PLAN.md 5.3.4), which the handshake reads.
    public static let liveEdgeTolerance: TimeInterval = 15
    /// Hard cap on one drain run (~60 s, NOOP's offload-session bound). A deep backlog drains in
    /// ~60 s slices instead of holding the link for minutes: the cap keeps the link responsive to
    /// the live HR stream (NOOP's stated reason for the ~60 s offload cap — "so live HR never
    /// starves"). The strap keeps everything past the last acked batch, so the next drain resumes
    /// where this one stopped; nothing is lost.
    public static let runCap: TimeInterval = 60

    /// Why the offload ended.
    public enum StopReason: Sendable, Equatable {
        /// No record or metadata for `quietTimeout` seconds.
        case quietTimeout
        /// A record arrived within `liveEdgeTolerance` of now.
        case reachedLiveEdge
        /// The BLE link dropped mid-drain.
        case linkDropped
        /// The caller declared the end of data, e.g. an empty GET_DATA_RANGE reply. [Unverified]
        case drainCompleted
        /// The drain ran for `runCap` seconds (backlog slices, so the link stays responsive to
        /// live HR; NOOP's ~60 s offload cap).
        case runCap
    }

    /// Why the offload is not running.
    public enum Phase: Sendable, Equatable {
        /// Nothing happening. `.sendHistoricalStarted` starts a drain.
        case idle
        /// Records and metadata are flowing.
        case draining
        /// The drain ended for the attached reason. A new `.sendHistoricalStarted` restarts it.
        case stopped(StopReason)
    }

    /// One thing that happened on the link or in the driver.
    public enum Event: Sendable, Equatable {
        /// The driver began the offload: it either just wrote SEND_HISTORICAL_DATA (cmd 22) or is
        /// about to; the emitted `.sendHistoricalData` effect is the authoritative write request.
        case sendHistoricalStarted
        /// A METADATA (type 49) frame closed a batch; `token` is `HistoricalMetadata.token(fromPayload:)`.
        case metadata(token: [UInt8])
        /// One HISTORICAL_DATA (type 47) record arrived, by its record unix time.
        case record(unixSeconds: UInt32)
        /// The caller observed a record within 15 s of now (for callers that check before handing
        /// the record over). The machine also detects this itself from `.record`.
        case recordNearNow
        /// The BLE link dropped.
        case linkDropped
        /// The quiet deadline passed with no traffic.
        case quietElapsed
        /// The caller declared the end of data. [Unverified] signal source.
        case drainCompleted
        /// The run cap (`runCap` seconds since the drain started) passed. The driver fires this
        /// when its wake-up at the run-cap deadline runs.
        case runCapElapsed
    }

    /// One thing the driver should do.
    public enum Effect: Sendable, Equatable {
        /// Write SEND_HISTORICAL_DATA (cmd 22, payload `[0x00]`) as a confirmed write.
        case sendHistoricalData
        /// Write HISTORICAL_DATA_RESULT (cmd 23) echoing the token, exactly once per metadata event.
        case sendResult(token: [UInt8])
        /// The drain ended; the driver should stop scheduling and may persist what it collected.
        case stop(StopReason)
    }

    public private(set) var phase: Phase = .idle
    /// When the drain should be declared quiet. Nil while idle or stopped. The driver schedules a
    /// wake-up at this instant and fires `.quietElapsed`.
    public private(set) var quietDeadline: Date?
    /// When the drain hits the `runCap` bound. Set when the drain starts, nil while idle or
    /// stopped. The driver schedules a wake-up at this instant and fires `.runCapElapsed`.
    public private(set) var runCapDeadline: Date?
    /// Records seen in the current (or last) drain.
    public private(set) var recordCount = 0
    /// Token of the most recent metadata, echoed exactly once.
    public private(set) var lastToken: [UInt8]?

    private let clock: any TierBClock

    public init(clock: any TierBClock) {
        self.clock = clock
    }

    /// Starts the quiet clock now, before the first frame. For drains someone is watching (a full sync): a strap
    /// with nothing pending answers SEND_HISTORICAL_DATA and then sends no history at all (2026-10-31 log), and a
    /// drain waiting for a first frame would sit out the whole run cap in silence. Routine drains keep the
    /// first-frame start. No-op unless draining.
    public mutating func armQuietDeadline() {
        guard phase == .draining else { return }
        quietDeadline = clock.now().addingTimeInterval(Self.quietTimeout)
    }

    /// Handles one event and returns the effects to perform, in order.
    public mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .sendHistoricalStarted:
            recordCount = 0
            lastToken = nil
            quietDeadline = nil
            runCapDeadline = clock.now().addingTimeInterval(Self.runCap)
            phase = .draining
            return [.sendHistoricalData]

        case .metadata(let token):
            guard phase == .draining else { return [] }
            lastToken = token
            quietDeadline = clock.now().addingTimeInterval(Self.quietTimeout)
            // One echo per metadata frame. A duplicate metadata with the same token means the
            // previous echo was lost in flight and the strap replayed the batch, so it is echoed
            // again rather than deduplicated.
            return [.sendResult(token: token)]

        case .record(let unixSeconds):
            guard phase == .draining else { return [] }
            recordCount += 1
            let now = clock.now()
            quietDeadline = now.addingTimeInterval(Self.quietTimeout)
            let recordTime = Date(timeIntervalSince1970: Double(unixSeconds))
            if abs(recordTime.timeIntervalSince(now)) <= Self.liveEdgeTolerance {
                return finish(.reachedLiveEdge)
            }
            return []

        case .recordNearNow:
            guard phase == .draining else { return [] }
            return finish(.reachedLiveEdge)

        case .quietElapsed:
            // The driver fires this when its wake-up at `quietDeadline` runs; the deadline check
            // keeps an early or stale firing from stopping a live drain.
            guard phase == .draining,
                  let deadline = quietDeadline,
                  clock.now() >= deadline
            else { return [] }
            return finish(.quietTimeout)

        case .runCapElapsed:
            // Same staleness shape as `.quietElapsed`: only a fire parked on this drain's cap
            // stops it.
            guard phase == .draining,
                  let deadline = runCapDeadline,
                  clock.now() >= deadline
            else { return [] }
            return finish(.runCap)

        case .linkDropped:
            guard phase == .draining else { return [] }
            return finish(.linkDropped)

        case .drainCompleted:
            guard phase == .draining else { return [] }
            return finish(.drainCompleted)
        }
    }

    private mutating func finish(_ reason: StopReason) -> [Effect] {
        phase = .stopped(reason)
        quietDeadline = nil
        runCapDeadline = nil
        return [.stop(reason)]
    }
}
