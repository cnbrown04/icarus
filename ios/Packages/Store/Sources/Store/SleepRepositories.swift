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
           skin_temp_raw, contact_fraction, quality, record_count, is_nap, algo_version, computed_at,
           resp_rate_brpm)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (band_id, start_ms) DO UPDATE SET
          end_ms = excluded.end_ms, duration_s = excluded.duration_s, resting_hr = excluded.resting_hr,
          rmssd_ms = excluded.rmssd_ms, resp_rate_raw = excluded.resp_rate_raw,
          skin_temp_raw = excluded.skin_temp_raw, contact_fraction = excluded.contact_fraction,
          resp_rate_brpm = excluded.resp_rate_brpm,
          quality = excluded.quality, record_count = excluded.record_count, is_nap = excluded.is_nap,
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
                session.isNap ? 1 : 0,
                SleepDeriver.algoVersion,
                computedAtMs,
                session.respiratoryRateBrpm,
            ])
            try statement.execute()
            written += changesCount
        }
        return written
    }

    /// Re-derives the sleep sessions that start in `[fromMs, toMs)`.
    ///
    /// `SleepDetector` runs over the range widened by `SleepDeriver.contextSeconds` on both sides, so
    /// a night crossing the range edge is seen whole and the HR baseline has its day of context. The
    /// range's stored sessions are then REPLACED: a session the new detection no longer produces is
    /// deleted with its hypnogram (a night whose start moved as records landed must not linger under
    /// its old key), and the detected ones are upserted. An unchanged session keeps its hypnogram, so
    /// `deriveSleepStageSegments` leaves it alone.
    ///
    /// Detection reads only timestamp, HR, contact and gravity; the full rows (R-R JSON included) are
    /// read for the detected windows alone. Returns the number of session rows written.
    @discardableResult
    public func deriveSleepSessions(
        from fromMs: Int64,
        to toMs: Int64,
        bandID: String,
        in timeZone: TimeZone,
        computedAtMs: Int64
    ) throws -> Int {
        guard toMs > fromMs else { return 0 }
        let context = SleepDeriver.contextSeconds * 1000
        let detection = try sleepDetectionRecords(bandID: bandID, from: fromMs - context, to: toMs + context)
        // User corrections (SleepEdits.swift) replace or drop the detected windows they claim, so a
        // re-derivation never undoes a hand-corrected bed or wake time.
        let windows = try sleepWindowsApplyingEdits(
            SleepDetector.detect(detection, in: timeZone),
            bandID: bandID,
            from: fromMs,
            to: toMs
        )
        let sessions = try windows.compactMap { window -> SleepSession? in
            let rows = try historicalRecordRows(
                bandID: bandID,
                from: window.startUnix * 1000,
                to: window.endUnix * 1000 + 1
            )
            return SleepDeriver.summarize(
                rows.map(\.sleepRecord),
                startUnix: window.startUnix,
                endUnix: window.endUnix,
                isNap: window.isNap
            )
        }

        // Drop the range's sessions the detection no longer produces, hypnograms first.
        let kept = Set(sessions.map { $0.startUnix * 1000 })
        let stale = try Int64.fetchAll(self, sql: """
            SELECT start_ms FROM sleep_session WHERE band_id = ? AND start_ms >= ? AND start_ms < ?
            """, arguments: [bandID, fromMs, toMs]).filter { !kept.contains($0) }
        for startMs in stale {
            try execute(
                sql: "DELETE FROM sleep_stage_segment WHERE band_id = ? AND session_start_ms = ?",
                arguments: [bandID, startMs]
            )
            try execute(
                sql: "DELETE FROM sleep_session WHERE band_id = ? AND start_ms = ?",
                arguments: [bandID, startMs]
            )
        }
        return try insertSleepSessions(sessions, bandID: bandID, computedAtMs: computedAtMs)
    }

    /// The detection inputs for `[fromMs, toMs)`, ascending: timestamp, HR, contact and gravity
    /// only. A raw cursor rather than `HistoricalRecordRow`, because detection reads days of 1 Hz
    /// records and must not pay for decoding every row's R-R JSON.
    public func sleepDetectionRecords(bandID: String, from fromMs: Int64, to toMs: Int64) throws -> [SleepRecord] {
        let cursor = try Row.fetchCursor(self, sql: """
            SELECT ts_ms, bpm, contact, gravity_x, gravity_y, gravity_z FROM historical_record
            WHERE band_id = ? AND ts_ms >= ? AND ts_ms < ? ORDER BY ts_ms
            """, arguments: [bandID, fromMs, toMs])
        var records: [SleepRecord] = []
        while let row = try cursor.next() {
            let tsMs: Int64 = row[0]
            let bpm: Int? = row[1]
            let contact: Int? = row[2]
            let x: Double? = row[3], y: Double? = row[4], z: Double? = row[5]
            var gravity: SleepRecord.Gravity?
            if let x, let y, let z {
                gravity = SleepRecord.Gravity(x: x, y: y, z: z)
            }
            records.append(SleepRecord(
                unixSeconds: tsMs / 1000,
                bpm: bpm.map { Double($0) },
                rrMs: [],
                skinContact: contact == 1,
                gravity: gravity
            ))
        }
        return records
    }

    // MARK: Sleep stage segments

    /// Replaces one session's staged hypnogram: deletes the session's existing segments, then inserts
    /// `segments`. Idempotent, so re-deriving a night never accumulates stale rows.
    ///
    /// The delete happens even when `segments` is empty, which is how a session that became too short
    /// to stage loses any earlier hypnogram. Returns the number of segment rows written.
    @discardableResult
    public func replaceSleepStageSegments(
        _ segments: [StageSegment],
        bandID: String,
        sessionStartMs: Int64,
        algoVersion: Int = SleepStager.algoVersion,
        computedAtMs: Int64
    ) throws -> Int {
        var written = 0
        try inSavepoint {
            try execute(
                sql: """
                DELETE FROM sleep_stage_segment
                WHERE band_id = ? AND session_start_ms = ?
                """,
                arguments: [bandID, sessionStartMs]
            )
            guard !segments.isEmpty else { return .commit }
            let statement = try makeStatement(sql: """
            INSERT INTO sleep_stage_segment
              (band_id, session_start_ms, start_ms, end_ms, stage, algo_version, computed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """)
            for segment in segments {
                statement.setUncheckedArguments([
                    bandID,
                    sessionStartMs,
                    segment.startUnix * 1000,
                    segment.endUnix * 1000,
                    segment.stage.rawValue,
                    algoVersion,
                    computedAtMs,
                ])
                try statement.execute()
                written += 1
            }
            return .commit
        }
        return written
    }

    /// Stages the derived sessions that overlap `[fromMs, toMs)` and persists their segments.
    ///
    /// Call after `deriveSleepSessions` in the same transaction. Work is bounded to sessions touched
    /// by the drained range: a batch that extends last night's session restages only that night, not
    /// the whole history. Sessions shorter than `SleepStager.minimumSessionSeconds` (~10 minutes) are
    /// deleted rather than staged. Existing rows written by the current `SleepStager.algoVersion` and
    /// covering exactly the same session window are left alone (cache-busting: bump `algoVersion` to
    /// force a restage).
    ///
    /// Each session reads `SleepStager.padLo` / `padHi` seconds of historical records around its
    /// window so the recipe's 5-/11-minute HR windows and RSA beat window reach the session edges.
    /// The staging inputs are gravity, bpm and rr_ms only:
    /// `resp_rate_raw` and `signal_quality` are constants in our stored data, and `spo2_red` /
    /// `spo2_ir` are constant too, so none carry staging signal. Respiration regularity comes from
    /// the R-R RSA path, which is also NOOP V2's path.
    ///
    /// Returns the number of segment rows written.
    @discardableResult
    public func deriveSleepStageSegments(
        from fromMs: Int64,
        to toMs: Int64,
        bandID: String,
        computedAtMs: Int64
    ) throws -> Int {
        guard toMs > fromMs else { return 0 }
        let sessions = try sleepSessionRows(bandID: bandID, from: fromMs, to: toMs)
        var written = 0
        for session in sessions {
            let startUnix = session.startMs / 1000
            let endUnix = session.endMs / 1000
            guard session.durationS >= SleepStager.minimumSessionSeconds,
                  endUnix > startUnix
            else {
                try replaceSleepStageSegments(
                    [],
                    bandID: bandID,
                    sessionStartMs: session.startMs,
                    computedAtMs: computedAtMs
                )
                continue
            }

            // Cache-busting guard: the same recipe already staged exactly this session window.
            if segmentsAreCurrent(
                bandID: bandID,
                session: session,
                algoVersion: SleepStager.algoVersion
            ) {
                continue
            }

            let rows = try historicalRecordRows(
                bandID: bandID,
                from: session.startMs - SleepStager.padLo * 1000,
                to: session.endMs + (SleepStager.padHi + 1) * 1000
            )
            let records = rows.map { row in
                let bpm = row.bpm.flatMap { value -> Double? in
                    let bpm = Double(value)
                    return (20...250).contains(bpm) ? bpm : nil
                }
                let gravity: StagingRecord.Gravity? = {
                    guard let x = row.gravityX, let y = row.gravityY, let z = row.gravityZ else {
                        return nil
                    }
                    return .init(x: x, y: y, z: z)
                }()
                return StagingRecord(
                    tsUnix: row.tsMs / 1000,
                    bpm: bpm,
                    contact: row.contact ?? false,
                    rrMs: row.rrMs ?? [],
                    gravity: gravity
                )
            }
            let staging = SleepStager.stage(
                records: records,
                fromUnix: startUnix,
                toUnix: endUnix,
                restingHR: session.restingHr
            )
            written += try replaceSleepStageSegments(
                staging.segments,
                bandID: bandID,
                sessionStartMs: session.startMs,
                computedAtMs: computedAtMs
            )
        }
        return written
    }

    /// True when every stored segment for this session carries the current algorithm version and the
    /// stored hypnogram tiles exactly the session window. A session that grew or was re-keyed fails
    /// the coverage test and is restaged.
    private func segmentsAreCurrent(
        bandID: String,
        session: SleepSessionRow,
        algoVersion: Int
    ) -> Bool {
        let rows: [SleepStageSegmentRow]? = try? SleepStageSegmentRow.fetchAll(
            self,
            sql: """
            SELECT * FROM sleep_stage_segment
            WHERE band_id = ? AND session_start_ms = ?
            ORDER BY start_ms, rowid
            """,
            arguments: [bandID, session.startMs]
        )
        guard let rows, !rows.isEmpty else { return false }
        guard rows.allSatisfy({ $0.algoVersion == algoVersion }) else { return false }
        guard rows.first?.startMs == session.startMs, rows.last?.endMs == session.endMs else {
            return false
        }
        return true
    }
}
