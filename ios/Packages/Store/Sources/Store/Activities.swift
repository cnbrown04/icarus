import Foundation
import GRDB
import Metrics

/// Errors from activity writes.
public enum ActivityStoreError: Error, Equatable {
    /// `endMs` is not after `startMs`.
    case invalidRange
    /// No live activity has that id.
    case notFound
}

/// One `activity` row (schema v9). Times are epoch ms UTC. `source` is `auto` or `manual`; `zoneMinutes` is the JSON
/// text of six minute totals (see the v9 migration).
public struct ActivityRow: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "activity"

    public var id: String
    public var bandID: String?
    public var startMs: Int64
    public var endMs: Int64
    public var kind: String
    public var source: String
    public var name: String?
    /// Strain on WHOOP's 0-21 display scale. Nil when the span had too little heart rate or no reserve.
    public var strain: Double?
    public var avgHR: Double?
    public var maxHR: Int?
    /// Estimated, see `ActivitySummary.kcal`.
    public var kcal: Double?
    /// JSON array of six credited minute totals.
    public var zoneMinutes: String
    public var algoVersion: Int
    public var updatedAt: Int64
    /// Epoch ms of a local delete. A non-nil value is a tombstone: hidden from reads, still blocking re-detection.
    public var deletedAt: Int64?

    public init(
        id: String,
        bandID: String?,
        startMs: Int64,
        endMs: Int64,
        kind: ActivityKind,
        source: String,
        name: String?,
        summary: ActivitySummary?,
        algoVersion: Int,
        updatedAt: Int64
    ) {
        self.id = id
        self.bandID = bandID
        self.startMs = startMs
        self.endMs = endMs
        self.kind = kind.rawValue
        self.source = source
        self.name = name
        self.strain = summary?.strain
        self.avgHR = summary?.avgHR
        self.maxHR = summary?.maxHR
        self.kcal = summary?.kcal
        self.zoneMinutes = Self.encodeZones(summary?.zoneMinutes ?? [])
        self.algoVersion = algoVersion
        self.updatedAt = updatedAt
        self.deletedAt = nil
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, source, name, strain, kcal
        case bandID = "band_id"
        case startMs = "start_ms"
        case endMs = "end_ms"
        case avgHR = "avg_hr"
        case maxHR = "max_hr"
        case zoneMinutes = "zone_minutes"
        case algoVersion = "algo_version"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    public var activityKind: ActivityKind {
        ActivityKind(rawValue: kind) ?? .other
    }

    public var isAuto: Bool {
        source == "auto"
    }

    /// `zoneMinutes` decoded. Six values, or empty when the JSON is unreadable.
    public var zoneMinuteValues: [Double] {
        guard let data = zoneMinutes.data(using: .utf8),
              let values = try? JSONDecoder().decode([Double].self, from: data) else { return [] }
        return values
    }

    static func encodeZones(_ values: [Double]) -> String {
        guard let data = try? JSONEncoder().encode(values), let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }
}

/// Activity reads and writes (schema v9). Call them inside `DatabaseWriter.write` or `read`.
///
/// Auto-detection: `detectActivities` runs `ActivityDetector` over stored minutes and reconciles the `auto` rows.
/// It never writes over a `manual` row or a tombstone, so user edits and deletes survive re-detection. It is local
/// only; no server sync.
extension Database {
    /// Live activities that start in [fromMs, toMs), oldest first.
    public func activities(from fromMs: Int64, to toMs: Int64) throws -> [ActivityRow] {
        try ActivityRow.fetchAll(self, sql: """
        SELECT * FROM activity WHERE deleted_at IS NULL AND start_ms >= ? AND start_ms < ? ORDER BY start_ms, id
        """, arguments: [fromMs, toMs])
    }

    /// One live activity, or nil when it is missing or deleted.
    public func activity(id: String) throws -> ActivityRow? {
        try ActivityRow.fetchOne(self, sql: "SELECT * FROM activity WHERE id = ? AND deleted_at IS NULL", arguments: [id])
    }

    /// Re-detects auto activities over minutes in [fromMs, toMs) and reconciles the `auto` rows there.
    ///
    /// - A detected bout that overlaps a live `manual` row or any tombstone is skipped.
    /// - A bout that overlaps a live `auto` row claims it: bounds and metrics are rewritten, kind and name kept.
    ///   Only a changed row is written, so a repeat run is a no-op.
    /// - Otherwise a new `auto` row is inserted, kind `other`.
    /// - A live `auto` row starting in the range that no bout claimed is removed (its bout is gone).
    ///
    /// Nothing runs without a profile (for HRmax and kcal) or a resting HR; then it returns 0 and leaves rows alone.
    /// Callers pass a range wider than the data they changed (see `HistoryPipeline`), so a bout that starts before
    /// the range is still seen whole.
    ///
    /// - Returns: the number of rows inserted, updated or removed.
    @discardableResult
    public func detectActivities(from fromMs: Int64, to toMs: Int64, in timeZone: TimeZone, computedAtMs: Int64) throws -> Int {
        guard toMs > fromMs else { return 0 }
        let context = try activityContext(at: toMs, in: timeZone)
        guard let restingHR = context.restingHR, let maxHR = context.maxHR,
              let threshold = ActivityDetector.thresholdBPM(restingHR: restingHR, maxHR: maxHR) else { return 0 }

        let minutes = try minuteMetricRows(from: fromMs, to: toMs).compactMap(\.minuteAggregate)
        let sleep = try Row.fetchAll(self, sql: """
        SELECT start_ms, end_ms FROM sleep_session WHERE end_ms > ? AND start_ms < ?
        """, arguments: [fromMs, toMs]).map { row -> Range<Int64> in
            let start: Int64 = row["start_ms"]
            let end: Int64 = row["end_ms"]
            return start..<end
        }
        let bouts = ActivityDetector.detect(minutes, thresholdBPM: threshold, sleep: sleep)
        let bandID = try currentBandID()
        let existing = try ActivityRow.fetchAll(self, sql: """
        SELECT * FROM activity WHERE start_ms < ? AND end_ms > ? ORDER BY start_ms, id
        """, arguments: [toMs, fromMs])

        var claimed = Set<String>()
        var changed = 0
        for bout in bouts {
            let overlapping = existing.filter { $0.startMs < bout.endMs && $0.endMs > bout.startMs }
            // A manual row or a tombstone owns its time: detection writes nothing there.
            if overlapping.contains(where: { !$0.isAuto || $0.deletedAt != nil }) { continue }

            let summary = ActivitySummary.make(
                startMs: bout.startMs,
                endMs: bout.endMs,
                minutes: minutes,
                restingHR: restingHR,
                maxHR: maxHR,
                profile: context.profile
            )
            if let target = overlapping.first(where: { !claimed.contains($0.id) }) {
                claimed.insert(target.id)
                var next = target
                next.startMs = bout.startMs
                next.endMs = bout.endMs
                next.applyMetrics(summary, algoVersion: ActivityDetector.algoVersion)
                if next != target {
                    next.updatedAt = computedAtMs
                    try next.update(self)
                    changed += 1
                }
            } else {
                let row = ActivityRow(
                    id: UUIDv7.make(unixMs: computedAtMs).uuidString.lowercased(),
                    bandID: bandID,
                    startMs: bout.startMs,
                    endMs: bout.endMs,
                    kind: .other,
                    source: "auto",
                    name: nil,
                    summary: summary,
                    algoVersion: ActivityDetector.algoVersion,
                    updatedAt: computedAtMs
                )
                try row.insert(self)
                changed += 1
            }
        }

        for row in existing where row.isAuto && row.deletedAt == nil && row.startMs >= fromMs && row.startMs < toMs
            && !claimed.contains(row.id) {
            _ = try row.delete(self)
            changed += 1
        }
        return changed
    }

    /// Records a workout the user timed. Its metrics come from the stored minutes in the span. Saved as `manual`.
    @discardableResult
    public func saveManualActivity(
        kind: ActivityKind,
        name: String?,
        startMs: Int64,
        endMs: Int64,
        computedAtMs: Int64
    ) throws -> ActivityRow {
        guard endMs > startMs else { throw ActivityStoreError.invalidRange }
        let context = try activityContext(at: endMs, in: nil)
        let minutes = try minuteMetricRows(from: LocalTime.roundDown(startMs, to: LocalTime.msPerMinute), to: endMs)
            .compactMap(\.minuteAggregate)
        var summary: ActivitySummary?
        if let restingHR = context.restingHR, let maxHR = context.maxHR {
            summary = ActivitySummary.make(
                startMs: startMs,
                endMs: endMs,
                minutes: minutes,
                restingHR: restingHR,
                maxHR: maxHR,
                profile: context.profile
            )
        }
        let row = ActivityRow(
            id: UUIDv7.make(unixMs: computedAtMs).uuidString.lowercased(),
            bandID: try currentBandID(),
            startMs: startMs,
            endMs: endMs,
            kind: kind,
            source: "manual",
            name: Self.trimmedName(name),
            summary: summary,
            algoVersion: ActivityDetector.algoVersion,
            updatedAt: computedAtMs
        )
        try row.insert(self)
        return row
    }

    /// Retypes and renames a live activity. Editing an `auto` row makes it `manual`, so detection stops touching it.
    public func updateActivity(id: String, kind: ActivityKind, name: String?, computedAtMs: Int64) throws {
        guard var row = try activity(id: id) else { throw ActivityStoreError.notFound }
        row.kind = kind.rawValue
        row.name = Self.trimmedName(name)
        row.source = "manual"
        row.updatedAt = computedAtMs
        try row.update(self)
    }

    /// Soft-deletes a live activity. The tombstone stays, so detection does not bring the span back.
    public func deleteActivity(id: String, computedAtMs: Int64) throws {
        try execute(sql: """
        UPDATE activity SET deleted_at = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL
        """, arguments: [computedAtMs, computedAtMs, id])
        guard changesCount > 0 else { throw ActivityStoreError.notFound }
    }

    // MARK: - Internals

    private struct ActivityContext {
        let profile: UserProfile?
        let restingHR: Double?
        let maxHR: Double?
    }

    /// Profile, resting HR and HRmax for a span ending at `ms`. Resting HR is the night's, else the latest main sleep's,
    /// as `DailyScores` borrows it. The zone is the profile's, else `timeZone`, else the device's.
    private func activityContext(at ms: Int64, in timeZone: TimeZone?) throws -> ActivityContext {
        let row = try profile()
        let zone = row?.timeZone ?? timeZone ?? TimeZone.current
        let day = LocalTime.localDay(containing: ms, in: zone)
        let profile = row?.userProfile(year: day.year)
        let maxHR: Double? = row.flatMap { row in
            if let hrMax = row.hrMax { return Double(hrMax) }
            return profile.map { HeartRateZones.maxHR(userEntered: nil, ageYears: $0.ageYears) }
        }
        var restingHR = try restingHeartRate(night: NightWindow.latestCompleted(nowMs: ms, in: zone), in: zone)
        if restingHR == nil {
            restingHR = try Double.fetchOne(self, sql: """
            SELECT resting_hr FROM sleep_session WHERE is_nap = 0 AND resting_hr IS NOT NULL AND end_ms < ?
            ORDER BY end_ms DESC LIMIT 1
            """, arguments: [ms])
        }
        return ActivityContext(profile: profile, restingHR: restingHR, maxHR: maxHR)
    }

    /// The band the auto rows are attributed to: the most recently seen one. Nil with no band.
    private func currentBandID() throws -> String? {
        try String.fetchOne(self, sql: """
        SELECT id FROM band ORDER BY COALESCE(last_seen_at, 0) DESC, created_at LIMIT 1
        """)
    }

    private static func trimmedName(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

private extension ActivityRow {
    /// Copies a summary's metrics onto the row. Leaves identity, bounds, kind, name and source alone.
    mutating func applyMetrics(_ summary: ActivitySummary, algoVersion: Int) {
        strain = summary.strain
        avgHR = summary.avgHR
        maxHR = summary.maxHR
        kcal = summary.kcal
        zoneMinutes = Self.encodeZones(summary.zoneMinutes)
        self.algoVersion = algoVersion
    }
}
