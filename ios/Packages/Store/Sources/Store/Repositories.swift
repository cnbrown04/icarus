import Foundation
import GRDB
import Metrics

/// Write paths. Call them inside `DatabaseWriter.write` so a batch shares one transaction (PLAN.md 7.3).
extension Database {
    // MARK: Bands

    /// Creates the band row on first sight of `peripheralUUID`, then keeps its name and last-seen time.
    /// A nil `name` keeps the stored one.
    @discardableResult
    public func upsertBand(peripheralUUID: UUID, name: String?, seenAtMs: Int64) throws -> String {
        let key = peripheralUUID.uuidString
        if let id = try String.fetchOne(self, sql: "SELECT id FROM band WHERE peripheral_uuid = ?", arguments: [key]) {
            try execute(
                sql: "UPDATE band SET name = COALESCE(?, name), last_seen_at = ? WHERE id = ?",
                arguments: [name, seenAtMs, id]
            )
            return id
        }
        let id = UUIDv7.make(unixMs: seenAtMs).uuidString.lowercased()
        try execute(
            sql: """
            INSERT INTO band (id, peripheral_uuid, name, tier_b_enabled, created_at, last_seen_at)
            VALUES (?, ?, ?, 0, ?, ?)
            """,
            arguments: [id, key, name, seenAtMs, seenAtMs]
        )
        return id
    }

    // MARK: Profile

    public func profile() throws -> ProfileRow? {
        try ProfileRow.fetchOne(self, key: 1)
    }

    /// Saves the single profile row. `version` increases by one on every save.
    public func saveProfile(_ draft: ProfileRow, atMs nowMs: Int64) throws {
        var row = draft
        row.id = 1
        row.version = (try profile()?.version ?? 0) + 1
        row.updatedAt = nowMs
        try row.save(self)
    }

    // MARK: Heart rate and R-R

    /// One accepted or rejected reading from a notification, already validated (see `ReadingPreparer`).
    public struct Reading: Sendable, Equatable {
        public let peripheralUUID: UUID
        public let tsMs: Int64
        public let bpm: Int
        public let contact: Bool?
        public let rr: [Interval]

        public init(peripheralUUID: UUID, tsMs: Int64, bpm: Int, contact: Bool?, rr: [Interval]) {
            self.peripheralUUID = peripheralUUID
            self.tsMs = tsMs
            self.bpm = bpm
            self.contact = contact
            self.rr = rr
        }
    }

    public struct Interval: Sendable, Equatable {
        public let seq: Int
        public let rrMs: Double
        public let accepted: Bool

        public init(seq: Int, rrMs: Double, accepted: Bool) {
            self.seq = seq
            self.rrMs = rrMs
            self.accepted = accepted
        }
    }

    /// `source` for the standard Heart Rate Measurement characteristic (PLAN.md 10.2).
    public static let standardHeartRateSource = 1

    public struct InsertCounts: Sendable, Equatable {
        public let heartRate: Int
        public let rrIntervals: Int
    }

    /// Inserts readings with `INSERT OR IGNORE`, so a repeated key is skipped and reported as not inserted.
    /// Creates band rows as needed.
    @discardableResult
    public func insertReadings(_ readings: [Reading]) throws -> InsertCounts {
        let heartRateStatement = try makeStatement(sql: """
        INSERT OR IGNORE INTO hr_sample (band_id, ts_ms, bpm, source, contact) VALUES (?, ?, ?, ?, ?)
        """)
        let rrStatement = try makeStatement(sql: """
        INSERT OR IGNORE INTO rr_interval (band_id, ts_ms, seq, rr_ms, accepted) VALUES (?, ?, ?, ?, ?)
        """)
        var bandIDs: [UUID: String] = [:]
        var heartRateInserted = 0
        var rrInserted = 0
        for reading in readings {
            let bandID: String
            if let known = bandIDs[reading.peripheralUUID] {
                bandID = known
            } else {
                bandID = try upsertBand(peripheralUUID: reading.peripheralUUID, name: nil, seenAtMs: reading.tsMs)
                bandIDs[reading.peripheralUUID] = bandID
            }
            heartRateStatement.setUncheckedArguments([
                bandID, reading.tsMs, reading.bpm, Self.standardHeartRateSource, reading.contact,
            ])
            try heartRateStatement.execute()
            heartRateInserted += changesCount
            for interval in reading.rr {
                rrStatement.setUncheckedArguments([bandID, reading.tsMs, interval.seq, interval.rrMs, interval.accepted])
                try rrStatement.execute()
                rrInserted += changesCount
            }
        }
        return InsertCounts(heartRate: heartRateInserted, rrIntervals: rrInserted)
    }

    // MARK: Band events

    /// Returns false when the same (band, ts, kind) event already exists.
    @discardableResult
    public func insertBandEvent(bandID: String, tsMs: Int64, kind: String, payload: String?) throws -> Bool {
        try execute(
            sql: "INSERT OR IGNORE INTO band_event (band_id, ts_ms, kind, payload) VALUES (?, ?, ?, ?)",
            arguments: [bandID, tsMs, kind, payload]
        )
        return changesCount > 0
    }

    // MARK: Minute metrics

    /// Writes recomputed minute rows. A row is rewritten only when a value changes. Each rewrite gets a new
    /// `sync_rev`, which is one more than the largest in the table, so the sync cursor (PLAN.md 11) sees it.
    /// Returns the number of rows whose values changed.
    @discardableResult
    public func upsertMinuteMetrics(_ metrics: [MinuteMetric], computedAtMs: Int64) throws -> Int {
        var changed = 0
        // Read the largest sync_rev once, only when a row actually changes.
        var nextRevision: Int64?
        for metric in metrics {
            let candidate = MinuteMetricRow(metric, computedAt: computedAtMs, syncRev: 0)
            if let existing = try MinuteMetricRow.fetchOne(self, key: candidate.minuteMs),
               existing.hasSameValues(as: candidate) {
                continue
            }
            let revision: Int64
            if let next = nextRevision {
                revision = next
            } else {
                let largest = try Int64.fetchOne(self, sql: "SELECT COALESCE(MAX(sync_rev), 0) FROM minute_metric") ?? 0
                revision = largest + 1
            }
            nextRevision = revision + 1
            var row = candidate
            row.syncRev = revision
            try row.save(self)
            changed += 1
        }
        return changed
    }
}
