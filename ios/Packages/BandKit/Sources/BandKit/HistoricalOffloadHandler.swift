import BandProtocol
import Foundation

/// Pure bridge from reassembled frames to `OffloadStateMachine` (PLAN.md 5.3.4). No CoreBluetooth.
///
/// `TierBController.receive` currently routes frames itself; when the history offload is wired in,
/// a driver can hold one of these handlers, feed every reassembled frame through `handle(frame:)`,
/// and perform the returned effects (write cmd 22/23, stop the drain). Because the handler is a
/// plain struct, the wiring needs no change to `TierBController` beyond one call site later.
///
/// The handler parses records with `HistoricalRecord` and extracts metadata tokens with
/// `HistoricalMetadata`, so version handling and token layout live in one place (BandProtocol).
/// Records whose version is unsupported are logged and skipped, never treated as a stop condition.
public struct HistoricalOffloadHandler {
    private var stateMachine: OffloadStateMachine

    public init(clock: any TierBClock) {
        self.stateMachine = OffloadStateMachine(clock: clock)
    }

    public var phase: OffloadStateMachine.Phase { stateMachine.phase }
    /// When to fire `quietElapsed()` — nil while idle or stopped (see `OffloadStateMachine`).
    public var quietDeadline: Date? { stateMachine.quietDeadline }
    public var recordCount: Int { stateMachine.recordCount }

    /// Starts a drain: returns the SEND_HISTORICAL_DATA write to perform.
    public mutating func start() -> [OffloadStateMachine.Effect] {
        stateMachine.handle(.sendHistoricalStarted)
    }

    /// The BLE link dropped.
    public mutating func linkDropped() -> [OffloadStateMachine.Effect] {
        stateMachine.handle(.linkDropped)
    }

    /// The quiet deadline passed with no traffic.
    public mutating func quietElapsed() -> [OffloadStateMachine.Effect] {
        stateMachine.handle(.quietElapsed)
    }

    /// The caller declared the end of data (e.g. an empty GET_DATA_RANGE reply).
    public mutating func drainCompleted() -> [OffloadStateMachine.Effect] {
        stateMachine.handle(.drainCompleted)
    }

    /// Feeds one reassembled frame from the band and returns the effects to perform.
    ///
    /// The METADATA byte rides the frame's `cmd` field (frame byte 6): 1 = HISTORY_START,
    /// 2 = HISTORY_END, 3 = HISTORY_COMPLETE (NOOP, hardware-verified on WHOOP 4). Only HISTORY_END
    /// carries the 8-byte trim cursor to echo (NOOP acks only HISTORY_END — echoing START or
    /// COMPLETE is ignored by the strap); HISTORY_COMPLETE means the strap's whole store is drained.
    /// Frames that are neither HISTORICAL_DATA nor METADATA are ignored.
    public mutating func handle(_ frame: Frame) -> [OffloadStateMachine.Effect] {
        switch frame.packetType {
        case .historicalData:
            do {
                let record = try HistoricalRecord.parse(frame)
                return stateMachine.handle(.record(unixSeconds: record.unixSeconds))
            } catch {
                // Unsupported versions and short payloads are expected on other firmware
                // generations (the S8 golden capture is version 12) — skip, do not stop.
                BandLog.tierB(.debug, "historical record skipped: \(error)")
                return []
            }
        case .metadata:
            switch frame.cmd {
            case 2:
                guard let token = HistoricalMetadata.token(fromPayload: frame.payload) else {
                    BandLog.tierB(.debug, "HISTORY_END too short for a token; ignored")
                    return []
                }
                return stateMachine.handle(.metadata(token: token))
            case 3:
                return stateMachine.handle(.drainCompleted)
            default:
                return [] // HISTORY_START: no ack; records follow immediately.
            }
        default:
            return []
        }
    }
}
