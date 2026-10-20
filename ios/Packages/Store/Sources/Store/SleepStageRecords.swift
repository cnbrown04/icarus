import Foundation
import GRDB
import Metrics

/// One persisted sleep-stage segment (`Schema.v4`).
///
/// `sessionStartMs` is the owning `sleep_session.start_ms`. It is a natural key, not an enforced
/// foreign key: derivation replaces a session's segments with delete-then-insert in one transaction,
/// and the session row is untouched. Lists are always ordered by `(start_ms, rowid)` so they can be
/// turned into a hypnogram without re-sorting.
public struct SleepStageSegmentRow: Codable, Equatable, Sendable, FetchableRecord {
    public static let databaseTableName = "sleep_stage_segment"

    public var rowid: Int64
    public var bandID: String
    public var sessionStartMs: Int64
    public var startMs: Int64
    public var endMs: Int64
    /// Raw stage string: `wake`, `light`, `deep`, `rem`.
    public var stage: String
    /// `SleepStager.algoVersion` at derivation time (cache-busting key).
    public var algoVersion: Int
    public var computedAt: Int64

    enum CodingKeys: String, CodingKey {
        case rowid
        case bandID = "band_id"
        case sessionStartMs = "session_start_ms"
        case startMs = "start_ms"
        case endMs = "end_ms"
        case stage
        case algoVersion = "algo_version"
        case computedAt = "computed_at"
    }

    /// The decoded stage, nil when a row carries an unknown value (written by a future recipe).
    public var stageValue: SleepStage? {
        SleepStage(rawValue: stage)
    }

    /// The persisted row as the package's value type, unix seconds.
    public var segment: StageSegment? {
        guard let stage = stageValue else { return nil }
        return StageSegment(startUnix: startMs / 1000, endUnix: endMs / 1000, stage: stage)
    }

    public init(
        rowid: Int64 = 0,
        bandID: String,
        sessionStartMs: Int64,
        startMs: Int64,
        endMs: Int64,
        stage: String,
        algoVersion: Int,
        computedAt: Int64
    ) {
        self.rowid = rowid
        self.bandID = bandID
        self.sessionStartMs = sessionStartMs
        self.startMs = startMs
        self.endMs = endMs
        self.stage = stage
        self.algoVersion = algoVersion
        self.computedAt = computedAt
    }
}
