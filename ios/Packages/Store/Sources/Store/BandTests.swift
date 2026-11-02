import Foundation
import GRDB

// Band Tests: a guided run in which the user does one known thing at a time (band off, back on, double-tap,
// charger on and off, a buzz) while the app marks the span of each step. The band's events and records inside
// those spans are labelled examples: what an unnamed event id means, and which record channel behaves like a
// temperature. This file stores the marks and reads the labelled data back.

/// One step of a run as it happened.
public struct BandTestMark: Sendable, Equatable, Codable {
    public let runID: String
    public let step: Int
    public let label: String
    public let startMs: Int64
    public let endMs: Int64
    /// The user skipped the step: its span is kept for the record but is never evidence.
    public let skipped: Bool

    public init(runID: String, step: Int, label: String, startMs: Int64, endMs: Int64, skipped: Bool) {
        self.runID = runID
        self.step = step
        self.label = label
        self.startMs = startMs
        self.endMs = endMs
        self.skipped = skipped
    }
}

/// A stored band event, decoded from `band_event`.
public struct StoredBandEvent: Sendable, Equatable, Codable {
    public let tsMs: Int64
    /// `BandEventKind.storageName`: a known name, or `event_<id>`.
    public let kind: String
    /// The event id, from the payload JSON.
    public let id: Int?
    /// The event's payload bytes as hex, from the payload JSON.
    public let hex: String?

    public init(tsMs: Int64, kind: String, id: Int?, hex: String?) {
        self.tsMs = tsMs
        self.kind = kind
        self.id = id
        self.hex = hex
    }
}

/// One second of the record channels Band Tests judges, oldest first. Channels are named by their frame offset
/// because what most of them measure is the open question.
public struct BandTestSample: Sendable, Equatable {
    public let tsMs: Int64
    public let bpm: Int?
    /// Frame 33, green light.
    public let ppgGreen: Int?
    /// Frames 72, 74, 76, 78 and 92: the temperature candidates.
    public let frame72: Int?
    public let frame74: Int?
    public let frame76: Int?
    public let frame78: Int?
    public let frame92: Int?
    public let gravity: (x: Double, y: Double, z: Double)?
    public let rrMs: [Double]

    public init(
        tsMs: Int64,
        bpm: Int? = nil,
        ppgGreen: Int? = nil,
        frame72: Int? = nil,
        frame74: Int? = nil,
        frame76: Int? = nil,
        frame78: Int? = nil,
        frame92: Int? = nil,
        gravity: (x: Double, y: Double, z: Double)? = nil,
        rrMs: [Double] = []
    ) {
        self.tsMs = tsMs
        self.bpm = bpm
        self.ppgGreen = ppgGreen
        self.frame72 = frame72
        self.frame74 = frame74
        self.frame76 = frame76
        self.frame78 = frame78
        self.frame92 = frame92
        self.gravity = gravity
        self.rrMs = rrMs
    }

    public static func == (lhs: BandTestSample, rhs: BandTestSample) -> Bool {
        lhs.tsMs == rhs.tsMs && lhs.bpm == rhs.bpm && lhs.ppgGreen == rhs.ppgGreen && lhs.frame72 == rhs.frame72
            && lhs.frame74 == rhs.frame74 && lhs.frame76 == rhs.frame76 && lhs.frame78 == rhs.frame78
            && lhs.frame92 == rhs.frame92 && lhs.rrMs == rhs.rrMs
            && lhs.gravity?.x == rhs.gravity?.x && lhs.gravity?.y == rhs.gravity?.y && lhs.gravity?.z == rhs.gravity?.z
    }
}

extension Database {
    // MARK: Events

    /// Stores one band event for the band with this peripheral identifier (created if new). `payload` is the
    /// JSON context the Event Log and Band Tests read. False when the same (band, time, kind) is already stored.
    @discardableResult
    public func recordBandEvent(peripheralUUID: UUID, tsMs: Int64, kind: String, payload: String?) throws -> Bool {
        let bandID = try String.fetchOne(self, sql: "SELECT id FROM band WHERE peripheral_uuid = ?",
                                         arguments: [peripheralUUID.uuidString])
            ?? upsertBand(peripheralUUID: peripheralUUID, name: nil, seenAtMs: tsMs)
        return try insertBandEvent(bandID: bandID, tsMs: tsMs, kind: kind, payload: payload)
    }

    /// Stored band events in `[fromMs, toMs)`, newest first, at most `limit`.
    public func bandEvents(fromMs: Int64 = 0, toMs: Int64 = .max, limit: Int = 500) throws -> [StoredBandEvent] {
        try BandEventRow.fetchAll(self, sql: """
            SELECT * FROM band_event WHERE ts_ms >= ? AND ts_ms < ? ORDER BY ts_ms DESC, rowid DESC LIMIT ?
            """, arguments: [fromMs, toMs, limit]).map { row in
            let json = row.payload.flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            return StoredBandEvent(tsMs: row.tsMs, kind: row.kind, id: json?["id"] as? Int, hex: json?["hex"] as? String)
        }
    }

    // MARK: Marks

    /// Stores (or replaces) one step of a run.
    public func saveBandTestMark(_ mark: BandTestMark) throws {
        try execute(sql: """
            INSERT OR REPLACE INTO band_test_mark (run_id, step, label, start_ms, end_ms, skipped) VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [mark.runID, mark.step, mark.label, mark.startMs, mark.endMs, mark.skipped ? 1 : 0])
    }

    /// Every run's marks, newest run first, steps in order.
    public func bandTestRuns() throws -> [[BandTestMark]] {
        let marks = try Row.fetchAll(self, sql: """
            SELECT run_id, step, label, start_ms, end_ms, skipped FROM band_test_mark ORDER BY start_ms
            """).map { row in
            BandTestMark(runID: row[0], step: row[1], label: row[2], startMs: row[3], endMs: row[4], skipped: row[5] as Bool)
        }
        let byRun = Dictionary(grouping: marks, by: \.runID)
        return byRun.values
            .map { $0.sorted { $0.step < $1.step } }
            .sorted { ($0.first?.startMs ?? 0) > ($1.first?.startMs ?? 0) }
    }

    // MARK: Samples

    /// The record channels Band Tests judges for `[fromMs, toMs)`, oldest first, from every band.
    public func bandTestSamples(fromMs: Int64, toMs: Int64) throws -> [BandTestSample] {
        try Row.fetchAll(self, sql: """
            SELECT ts_ms, bpm, ppg_green, skin_temp_raw, ambient_drive, led_drive1, led_drive2, aux_92_raw,
                   gravity_x, gravity_y, gravity_z, rr_ms
            FROM historical_record WHERE ts_ms >= ? AND ts_ms < ? ORDER BY ts_ms
            """, arguments: [fromMs, toMs]).map { row in
            let x: Double? = row[8], y: Double? = row[9], z: Double? = row[10]
            let rr: String? = row[11]
            return BandTestSample(
                tsMs: row[0],
                bpm: row[1],
                ppgGreen: row[2],
                frame72: row[3],
                frame74: row[4],
                frame76: row[5],
                frame78: row[6],
                frame92: row[7],
                gravity: x.flatMap { x in y.flatMap { y in z.map { (x, y, $0) } } },
                rrMs: rr.map(Self.parseIntervals) ?? []
            )
        }
    }
}
