import Foundation
import GRDB
import Metrics

/// History offload and sleep sessions (PLAN.md 5.3.4, 8.1). Write paths follow the
/// `Repositories.swift` conventions: call them inside `DatabaseWriter.write` so a batch shares
/// one transaction (PLAN.md 7.3).
extension Database {
    // MARK: Historical records

    /// One decoded historical record ready for storage. Deliberately protocol-free: the caller
    /// converts BandProtocol's `HistoricalRecord` into this, so Store keeps no BLE dependency.
    public struct HistoricalSample: Sendable, Equatable {
        public let peripheralUUID: UUID
        /// Record unix time in ms (record seconds × 1000, PLAN.md 10.1 convention).
        public let tsMs: Int64
        /// Record layout version (the frame `seq` byte); 24 = WHOOP 4.0 DSP record.
        public let version: Int
        /// Heart rate, or nil when the strap recorded no reading (raw byte 0).
        public let bpm: Int?
        public let contact: Bool?
        /// R-R values in milliseconds.
        public let rrMs: [Double]
        public let ppgGreen: Int?
        public let ppgRedIr: Int?
        public let spo2Red: Int?
        public let spo2Ir: Int?
        public let skinTempRaw: Int?
        public let respRateRaw: Int?
        public let signalQuality: Int?
        /// Both gravity triplets, in g (v3).
        public let gravityX: Double?
        public let gravityY: Double?
        public let gravityZ: Double?
        public let gravity2X: Double?
        public let gravity2Y: Double?
        public let gravity2Z: Double?
        /// Raw ambient-light and LED drive bytes (v3).
        public let ambientDrive: Int?
        public let ledDrive1: Int?
        public let ledDrive2: Int?

        public init(
            peripheralUUID: UUID,
            tsMs: Int64,
            version: Int,
            bpm: Int?,
            contact: Bool?,
            rrMs: [Double],
            ppgGreen: Int? = nil,
            ppgRedIr: Int? = nil,
            spo2Red: Int? = nil,
            spo2Ir: Int? = nil,
            skinTempRaw: Int? = nil,
            respRateRaw: Int? = nil,
            signalQuality: Int? = nil,
            gravityX: Double? = nil,
            gravityY: Double? = nil,
            gravityZ: Double? = nil,
            gravity2X: Double? = nil,
            gravity2Y: Double? = nil,
            gravity2Z: Double? = nil,
            ambientDrive: Int? = nil,
            ledDrive1: Int? = nil,
            ledDrive2: Int? = nil
        ) {
            self.peripheralUUID = peripheralUUID
            self.tsMs = tsMs
            self.version = version
            self.bpm = bpm
            self.contact = contact
            self.rrMs = rrMs
            self.ppgGreen = ppgGreen
            self.ppgRedIr = ppgRedIr
            self.spo2Red = spo2Red
            self.spo2Ir = spo2Ir
            self.skinTempRaw = skinTempRaw
            self.respRateRaw = respRateRaw
            self.signalQuality = signalQuality
            self.gravityX = gravityX
            self.gravityY = gravityY
            self.gravityZ = gravityZ
            self.gravity2X = gravity2X
            self.gravity2Y = gravity2Y
            self.gravity2Z = gravity2Z
            self.ambientDrive = ambientDrive
            self.ledDrive1 = ledDrive1
            self.ledDrive2 = ledDrive2
        }
    }

    /// Inserts offloaded records with `INSERT OR IGNORE`, so a replayed batch (the strap repeats
    /// it until its ack lands) is deduped by (band, timestamp) and reported as not inserted.
    /// Creates band rows as needed, like `insertReadings`.
    @discardableResult
    public func insertHistoricalSamples(_ samples: [HistoricalSample]) throws -> Int {
        let statement = try makeStatement(sql: """
        INSERT OR IGNORE INTO historical_record
          (band_id, ts_ms, version, bpm, contact, rr_ms, ppg_green, ppg_red_ir, spo2_red, spo2_ir,
           skin_temp_raw, resp_rate_raw, signal_quality, gravity_x, gravity_y, gravity_z,
           gravity2_x, gravity2_y, gravity2_z, ambient_drive, led_drive1, led_drive2)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """)
        var bandIDs: [UUID: String] = [:]
        var inserted = 0
        for sample in samples {
            let bandID: String
            if let known = bandIDs[sample.peripheralUUID] {
                bandID = known
            } else {
                bandID = try upsertBand(peripheralUUID: sample.peripheralUUID, name: nil, seenAtMs: sample.tsMs)
                bandIDs[sample.peripheralUUID] = bandID
            }
            statement.setUncheckedArguments([
                bandID,
                sample.tsMs,
                sample.version,
                sample.bpm,
                sample.contact.map { $0 ? 1 : 0 },
                Self.jsonRR(sample.rrMs),
                sample.ppgGreen,
                sample.ppgRedIr,
                sample.spo2Red,
                sample.spo2Ir,
                sample.skinTempRaw,
                sample.respRateRaw,
                sample.signalQuality,
                sample.gravityX,
                sample.gravityY,
                sample.gravityZ,
                sample.gravity2X,
                sample.gravity2Y,
                sample.gravity2Z,
                sample.ambientDrive,
                sample.ledDrive1,
                sample.ledDrive2,
            ])
            try statement.execute()
            inserted += changesCount
        }
        return inserted
    }

    /// JSON array text for the `rr_ms` column. An empty array is stored as `[]`, not NULL, so
    /// "record with no beats" is distinct from "older row shape".
    private static func jsonRR(_ rrMs: [Double]) -> String {
        let encoded = rrMs.map { value -> String in
            value == value.rounded() ? String(Int(value)) : String(value)
        }
        return "[" + encoded.joined(separator: ",") + "]"
    }

    // MARK: Sleep sessions

    /// Writes derived sessions with an upsert on (band, start): a recompute that extends a session
    /// overwrites its earlier partial self. Returns the number of rows written.
    @discardableResult
    public func insertSleepSessions(
        _ sessions: [SleepSession],
        bandID: String,
        computedAtMs: Int64
    ) throws -> Int {
        let statement = try makeStatement(sql: """
        INSERT INTO sleep_session
          (band_id, start_ms, end_ms, duration_s, resting_hr, rmssd_ms, resp_rate_raw,
           skin_temp_raw, contact_fraction, quality, record_count, algo_version, computed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (band_id, start_ms) DO UPDATE SET
          end_ms = excluded.end_ms, duration_s = excluded.duration_s, resting_hr = excluded.resting_hr,
          rmssd_ms = excluded.rmssd_ms, resp_rate_raw = excluded.resp_rate_raw,
          skin_temp_raw = excluded.skin_temp_raw, contact_fraction = excluded.contact_fraction,
          quality = excluded.quality, record_count = excluded.record_count,
          algo_version = excluded.algo_version, computed_at = excluded.computed_at
        """)
        var written = 0
        for session in sessions {
            statement.setUncheckedArguments([
                bandID,
                session.startUnix * 1000,
                session.endUnix * 1000,
                session.durationSeconds,
                session.restingHeartRate,
                session.rmssdMs,
                session.respRateRawMedian,
                session.skinTempRawMedian,
                session.contactFraction,
                session.quality.rawValue,
                session.recordCount,
                SleepDeriver.algoVersion,
                computedAtMs,
            ])
            try statement.execute()
            written += changesCount
        }
        return written
    }

    /// Derives and stores sleep sessions for the records in `[fromMs, toMs)`.
    ///
    /// The read is widened by `SleepDeriver.maxGapSeconds` on both sides so a session straddling
    /// the range edge is derived whole, then only sessions overlapping the requested range are
    /// written. That makes day-by-day incremental recomputes stable: a night recomputed after more
    /// records landed replaces its earlier partial row.
    @discardableResult
    public func deriveSleepSessions(
        from fromMs: Int64,
        to toMs: Int64,
        bandID: String,
        in timeZone: TimeZone,
        computedAtMs: Int64
    ) throws -> Int {
        let margin = SleepDeriver.maxGapSeconds * 1000
        let rows = try historicalRecordRows(bandID: bandID, from: fromMs - margin, to: toMs + margin)
        let sessions = SleepDeriver.derive(rows.map(\.sleepRecord), in: timeZone).filter { session in
            session.endUnix * 1000 >= fromMs && session.startUnix * 1000 < toMs
        }
        return try insertSleepSessions(sessions, bandID: bandID, computedAtMs: computedAtMs)
    }
}
