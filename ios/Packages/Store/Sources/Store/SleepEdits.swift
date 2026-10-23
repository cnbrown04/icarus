import Foundation
import GRDB
import Metrics

/// User corrections to detected sleep (v6 `sleep_edit`): retime a night's bed and wake times, or
/// delete a falsely detected night.
///
/// Re-derivation REPLACES the sessions in a range (`deriveSleepSessions`), so a correction written
/// into `sleep_session` would be wiped on the next drain. Corrections live in their own table and are
/// applied on every detection pass instead: a detected window that overlaps a correction's original
/// window takes the corrected bounds (retime) or is dropped (dismiss). Summaries and hypnograms are
/// then rebuilt from the raw records inside the corrected bounds, so the stored night always matches
/// its edit.
public enum SleepEditKind: String, Sendable, Equatable {
    case retime
    case dismiss
}

/// One stored correction. `newEndMs` is nil for a dismissed night, whose `newStartMs` equals its
/// original start so the row is still addressable by the night's displayed start.
public struct SleepEditRow: Codable, Equatable, Sendable, FetchableRecord {
    public static let databaseTableName = "sleep_edit"

    public var rowid: Int64
    public var bandID: String
    public var originalStartMs: Int64
    public var originalEndMs: Int64
    public var newStartMs: Int64
    public var newEndMs: Int64?
    /// Raw `SleepEditKind` value.
    public var kind: String
    public var createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case rowid
        case bandID = "band_id"
        case originalStartMs = "original_start_ms"
        case originalEndMs = "original_end_ms"
        case newStartMs = "new_start_ms"
        case newEndMs = "new_end_ms"
        case kind
        case createdAt = "created_at"
    }

    public var kindValue: SleepEditKind {
        SleepEditKind(rawValue: kind) ?? .retime
    }
}

/// Why a sleep correction was refused. The messages are shown to the user as they are.
public enum SleepEditError: Error, Equatable, LocalizedError {
    case endNotAfterStart
    case durationOutOfRange
    case endsInTheFuture
    case overlapsAnotherNight
    case noRecordedData

    public var errorDescription: String? {
        switch self {
        case .endNotAfterStart: "The wake time must be after the bed time."
        case .durationOutOfRange: "A night must be between 30 minutes and 16 hours long."
        case .endsInTheFuture: "A night cannot end in the future."
        case .overlapsAnotherNight: "These times overlap another night."
        case .noRecordedData: "The band recorded no data between these times."
        }
    }
}

/// The guard rails every correction passes before it is stored (NOOP `SleepEditGuard`, adapted: a
/// correction is refused rather than clamped, so the user sees why).
public enum SleepEditRules {
    /// Shortest and longest night a correction may describe. Matches the detector's own bounds
    /// (`SleepDetector.minSleepSeconds` is 60 min; the edit floor is looser so a short nap can be fixed).
    public static let minDurationMs: Int64 = 30 * 60 * 1000
    public static let maxDurationMs: Int64 = SleepDetector.maxSleepSeconds * 1000
    /// Clock-skew allowance for "not in the future", the same slack NOOP uses.
    public static let futureSlackMs: Int64 = 5 * 60 * 1000

    /// Throws for an inverted, out-of-bounds or future window. Overlap and recorded data need the
    /// store, so they are checked by `Database.retimeSleepSession`.
    public static func validate(startMs: Int64, endMs: Int64, nowMs: Int64) throws {
        guard endMs > startMs else { throw SleepEditError.endNotAfterStart }
        let duration = endMs - startMs
        guard (minDurationMs...maxDurationMs).contains(duration) else { throw SleepEditError.durationOutOfRange }
        guard endMs <= nowMs + futureSlackMs else { throw SleepEditError.endsInTheFuture }
    }
}

extension Database {
    // MARK: Reads

    /// Every correction for a band, oldest original first.
    public func sleepEdits(bandID: String) throws -> [SleepEditRow] {
        try SleepEditRow.fetchAll(self, sql: """
        SELECT * FROM sleep_edit WHERE band_id = ? ORDER BY original_start_ms
        """, arguments: [bandID])
    }

    /// The correction that produced the night now displayed at `sessionStartMs`, if any.
    /// A retime is keyed by its corrected start; a dismiss keeps its original start there.
    func sleepEdit(bandID: String, displayedStartMs: Int64) throws -> SleepEditRow? {
        try SleepEditRow.fetchOne(self, sql: """
        SELECT * FROM sleep_edit WHERE band_id = ? AND new_start_ms = ?
        """, arguments: [bandID, displayedStartMs])
    }

    // MARK: Writes

    /// Moves a night's bed and wake times to `newStartMs`...`newEndMs`, then re-derives the affected
    /// range so the stored session and its hypnogram show the correction at once.
    ///
    /// `sessionStartMs` / `sessionEndMs` are the night as it is displayed now. A night that was already
    /// corrected keeps its first original window, so a later correction still matches the detection.
    /// Refuses (throws `SleepEditError`) an inverted, too short or too long, future, overlapping or
    /// unrecorded window. Call inside `DatabaseWriter.write`.
    public func retimeSleepSession(
        bandID: String,
        sessionStartMs: Int64,
        sessionEndMs: Int64,
        newStartMs: Int64,
        newEndMs: Int64,
        in timeZone: TimeZone,
        nowMs: Int64
    ) throws {
        try SleepEditRules.validate(startMs: newStartMs, endMs: newEndMs, nowMs: nowMs)
        let original = try originalWindow(bandID: bandID, displayedStartMs: sessionStartMs, displayedEndMs: sessionEndMs)

        // Another night may not sit inside the corrected window. The night's own stored row (and any
        // detection overlapping its original window) is this same night, so it is not a conflict.
        let conflicts = try Int.fetchOne(self, sql: """
        SELECT COUNT(*) FROM sleep_session
        WHERE band_id = ? AND start_ms < ? AND end_ms > ?
          AND NOT (start_ms < ? AND end_ms > ?)
        """, arguments: [bandID, newEndMs, newStartMs, original.endMs, original.startMs]) ?? 0
        guard conflicts == 0 else { throw SleepEditError.overlapsAnotherNight }

        let records = try Int.fetchOne(self, sql: """
        SELECT COUNT(*) FROM historical_record WHERE band_id = ? AND ts_ms >= ? AND ts_ms < ?
        """, arguments: [bandID, newStartMs, newEndMs + 1]) ?? 0
        guard records > 0 else { throw SleepEditError.noRecordedData }

        try upsertSleepEdit(
            bandID: bandID,
            originalStartMs: original.startMs,
            originalEndMs: original.endMs,
            newStartMs: newStartMs,
            newEndMs: newEndMs,
            kind: .retime,
            createdAtMs: nowMs
        )
        try rederiveSleepEdited(
            bandID: bandID,
            spans: [original, (sessionStartMs, sessionEndMs), (newStartMs, newEndMs)],
            in: timeZone,
            nowMs: nowMs
        )
    }

    /// Deletes a falsely detected night. Its detection is suppressed on every re-derivation (the
    /// dismiss row), and its stored session and hypnogram are removed now. Call inside `DatabaseWriter.write`.
    public func dismissSleepSession(
        bandID: String,
        sessionStartMs: Int64,
        sessionEndMs: Int64,
        in timeZone: TimeZone,
        nowMs: Int64
    ) throws {
        let original = try originalWindow(bandID: bandID, displayedStartMs: sessionStartMs, displayedEndMs: sessionEndMs)
        try upsertSleepEdit(
            bandID: bandID,
            originalStartMs: original.startMs,
            originalEndMs: original.endMs,
            newStartMs: original.startMs,
            newEndMs: nil,
            kind: .dismiss,
            createdAtMs: nowMs
        )
        try rederiveSleepEdited(
            bandID: bandID,
            spans: [original, (sessionStartMs, sessionEndMs)],
            in: timeZone,
            nowMs: nowMs
        )
    }

    /// Undoes the correction behind the night displayed at `sessionStartMs` (a retime or a dismissal),
    /// so detection's own bounds come back on the next pass. Returns false when there was none.
    @discardableResult
    public func removeSleepEdit(
        bandID: String,
        sessionStartMs: Int64,
        sessionEndMs: Int64,
        in timeZone: TimeZone,
        nowMs: Int64
    ) throws -> Bool {
        guard let edit = try sleepEdit(bandID: bandID, displayedStartMs: sessionStartMs) else { return false }
        try execute(sql: "DELETE FROM sleep_edit WHERE rowid = ?", arguments: [edit.rowid])
        var spans: [(startMs: Int64, endMs: Int64)] = [(sessionStartMs, sessionEndMs), (edit.originalStartMs, edit.originalEndMs)]
        if let newEnd = edit.newEndMs {
            spans.append((edit.newStartMs, newEnd))
        }
        try rederiveSleepEdited(bandID: bandID, spans: spans, in: timeZone, nowMs: nowMs)
        return true
    }

    // MARK: Derivation hook

    /// The windows `deriveSleepSessions` should store for `[fromMs, toMs)`: the detection `detected`
    /// with the band's corrections applied.
    ///
    /// A correction claims every detected window overlapping its original window (or, for a retime,
    /// its corrected window). A dismiss drops what it claims. A retime is emitted at its corrected
    /// bounds whether or not detection still finds the night, so the correction survives drift. A
    /// retime counts as in range when either its original or corrected start is, so a re-derivation
    /// over only the corrected span still keeps it.
    func sleepWindowsApplyingEdits(
        _ detected: [SleepDetector.Window],
        bandID: String,
        from fromMs: Int64,
        to toMs: Int64
    ) throws -> [SleepDetector.Window] {
        let edits = try sleepEdits(bandID: bandID)
        guard !edits.isEmpty else {
            return detected.filter { inRange($0.startUnix * 1000, from: fromMs, to: toMs) }
        }

        var claimed = Set<Int>()
        var corrected: [SleepDetector.Window] = []
        for edit in edits {
            let original = (start: edit.originalStartMs / 1000, end: edit.originalEndMs / 1000)
            let corrections = edit.newEndMs.map { (start: edit.newStartMs / 1000, end: $0 / 1000) }
            for (index, window) in detected.enumerated() {
                let overlapsOriginal = window.startUnix < original.end && original.start < window.endUnix
                let overlapsCorrected = corrections.map { window.startUnix < $0.end && $0.start < window.endUnix } ?? false
                if overlapsOriginal || overlapsCorrected {
                    claimed.insert(index)
                }
            }
            if edit.kindValue == .retime, let corrections {
                let inRange = inRange(edit.originalStartMs, from: fromMs, to: toMs)
                    || inRange(edit.newStartMs, from: fromMs, to: toMs)
                if inRange {
                    corrected.append(SleepDetector.Window(startUnix: corrections.start, endUnix: corrections.end, isNap: false))
                }
            }
        }

        let unclaimed = detected.indices
            .filter { !claimed.contains($0) && inRange(detected[$0].startUnix * 1000, from: fromMs, to: toMs) }
            .map { detected[$0] }
        return unclaimed + corrected
    }

    // MARK: Helpers

    private func inRange(_ ms: Int64, from fromMs: Int64, to toMs: Int64) -> Bool {
        ms >= fromMs && ms < toMs
    }

    /// The detected window a correction is made against: the existing correction's original when the
    /// night was already corrected, else the night as displayed (which is the detected window).
    private func originalWindow(
        bandID: String,
        displayedStartMs: Int64,
        displayedEndMs: Int64
    ) throws -> (startMs: Int64, endMs: Int64) {
        if let existing = try sleepEdit(bandID: bandID, displayedStartMs: displayedStartMs) {
            return (existing.originalStartMs, existing.originalEndMs)
        }
        return (displayedStartMs, displayedEndMs)
    }

    private func upsertSleepEdit(
        bandID: String,
        originalStartMs: Int64,
        originalEndMs: Int64,
        newStartMs: Int64,
        newEndMs: Int64?,
        kind: SleepEditKind,
        createdAtMs: Int64
    ) throws {
        try execute(sql: """
        INSERT INTO sleep_edit
          (band_id, original_start_ms, original_end_ms, new_start_ms, new_end_ms, kind, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (band_id, original_start_ms) DO UPDATE SET
          original_end_ms = excluded.original_end_ms, new_start_ms = excluded.new_start_ms,
          new_end_ms = excluded.new_end_ms, kind = excluded.kind, created_at = excluded.created_at
        """, arguments: [bandID, originalStartMs, originalEndMs, newStartMs, newEndMs, kind.rawValue, createdAtMs])
    }

    /// Re-derives sessions and hypnograms over the span covering every given window, so the stored
    /// night matches the correction and nothing the correction touched is left stale.
    private func rederiveSleepEdited(
        bandID: String,
        spans: [(startMs: Int64, endMs: Int64)],
        in timeZone: TimeZone,
        nowMs: Int64
    ) throws {
        let fromMs = spans.map(\.startMs).min() ?? 0
        let toMs = (spans.map(\.endMs).max() ?? 0) + 1
        try deriveSleepSessions(from: fromMs, to: toMs, bandID: bandID, in: timeZone, computedAtMs: nowMs)
        try deriveSleepStageSegments(from: fromMs, to: toMs, bandID: bandID, computedAtMs: nowMs)
    }
}
