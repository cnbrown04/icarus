import Foundation

/// Live progress of the strap's history offload (PLAN.md 5.3.4), surfaced to the app so a drain
/// is visible while it happens instead of only when the graphs change later.
///
/// Emitted on a drain start, at most about twice a second while batches are acked, and once when
/// the drain ends. The counts are O(1) to read, so the emission never adds per-record work.
public struct DrainProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// No drain is running.
        case idle
        /// Records and metadata are flowing.
        case draining
    }

    public let phase: Phase
    /// Records kept by the current (or, when idle, the last) drain.
    public let recordsThisDrain: Int
    /// Records kept across every drain since the link opened.
    public let totalThisSession: Int
    /// The strap's reported ring backlog, when a GET_DATA_RANGE reply has been decoded.
    public let pagesBehind: Int?
    /// Why the last drain stopped. Nil while draining (and before the first drain).
    public let stopReason: OffloadStateMachine.StopReason?
    /// The controller clock's time this progress was sampled.
    public let at: Date

    public init(
        phase: Phase,
        recordsThisDrain: Int,
        totalThisSession: Int,
        pagesBehind: Int?,
        stopReason: OffloadStateMachine.StopReason?,
        at: Date
    ) {
        self.phase = phase
        self.recordsThisDrain = recordsThisDrain
        self.totalThisSession = totalThisSession
        self.pagesBehind = pagesBehind
        self.stopReason = stopReason
        self.at = at
    }

    public var isDraining: Bool { phase == .draining }
}

extension OffloadStateMachine.StopReason {
    /// A short, user-facing description for the Device screen.
    public var displayText: String {
        switch self {
        case .quietTimeout: "band went quiet"
        case .reachedLiveEdge: "caught up to live"
        case .linkDropped: "link dropped"
        case .drainCompleted: "history complete"
        case .runCap: "time limit reached"
        }
    }

    /// True when the drain did not end by cleanly reaching the live edge or the history end.
    /// These are the reasons the Device screen calls out after the record count.
    public var isAbnormal: Bool {
        switch self {
        case .quietTimeout, .linkDropped, .runCap: true
        case .reachedLiveEdge, .drainCompleted: false
        }
    }
}
