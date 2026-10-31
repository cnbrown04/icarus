import GRDB

/// Migrations for the local store. Each migration is append-only (PLAN.md 10.2).
enum Schema {
    static func registerMigrations(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1") { db in
            try db.execute(sql: v1)
        }
        migrator.registerMigration("v2") { db in
            try db.execute(sql: v2)
        }
        migrator.registerMigration("v3") { db in
            try db.execute(sql: v3)
        }
        migrator.registerMigration("v4") { db in
            try db.execute(sql: v4)
        }
        migrator.registerMigration("v5") { db in
            try db.execute(sql: v5)
        }
        migrator.registerMigration("v6") { db in
            try db.execute(sql: v6)
        }
        migrator.registerMigration("v7") { db in
            try db.execute(sql: v7)
        }
        migrator.registerMigration("v8") { db in
            try db.execute(sql: v8)
        }
        migrator.registerMigration("v9") { db in
            try db.execute(sql: v9)
        }
        migrator.registerMigration("v10") { db in
            try db.execute(sql: v10)
        }
        migrator.registerMigration("v11") { db in
            try db.execute(sql: v11)
        }
    }

    /// Migration v1, copied from PLAN.md 10.2. Times are epoch ms UTC.
    static let v1 = """
    CREATE TABLE profile (id INTEGER PRIMARY KEY CHECK (id = 1), formula_sex TEXT CHECK (formula_sex IN ('male','female')),
      birth_year INTEGER, height_cm REAL, weight_kg REAL, hr_max INTEGER, tz TEXT NOT NULL DEFAULT 'America/Chicago',
      version INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL);
    CREATE TABLE band (id TEXT PRIMARY KEY /* UUIDv7 */, peripheral_uuid TEXT NOT NULL UNIQUE /* CB identifier, per phone */,
      name TEXT, firmware TEXT, tier_b_enabled INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, last_seen_at INTEGER);
    CREATE TABLE hr_sample (rowid INTEGER PRIMARY KEY /* sync cursor */, band_id TEXT NOT NULL REFERENCES band(id),
      ts_ms INTEGER NOT NULL, bpm INTEGER NOT NULL CHECK (bpm BETWEEN 20 AND 250),
      source INTEGER NOT NULL /* 1 std_2a37, 2 custom_realtime, 3 custom_history */, contact INTEGER /* NULL = unknown */,
      UNIQUE (band_id, ts_ms, source));
    CREATE INDEX hr_sample_ts ON hr_sample(ts_ms);
    CREATE TABLE rr_interval (rowid INTEGER PRIMARY KEY, band_id TEXT NOT NULL REFERENCES band(id),
      ts_ms INTEGER NOT NULL /* receive time of carrying notification */, seq INTEGER NOT NULL /* index within it */,
      rr_ms REAL NOT NULL, accepted INTEGER NOT NULL /* §8.2 */, UNIQUE (band_id, ts_ms, seq));
    CREATE INDEX rr_interval_ts ON rr_interval(ts_ms);
    CREATE TABLE minute_metric (minute_ms INTEGER PRIMARY KEY, hr_avg REAL, hr_min INTEGER, hr_max INTEGER, hr_n INTEGER,
      rmssd_ms REAL, sdnn_ms REAL, baevsky_sqrt REAL,
      stress INTEGER, stress_state TEXT /* value|calibrating|exertion|insufficient|hr_only */,
      kcal REAL, active_kcal REAL, kcal_estimated INTEGER,
      algo_version INTEGER NOT NULL, computed_at INTEGER NOT NULL, sync_rev INTEGER NOT NULL /* bump on recompute */);
    CREATE TABLE band_event (rowid INTEGER PRIMARY KEY, band_id TEXT NOT NULL, ts_ms INTEGER NOT NULL,
      kind TEXT NOT NULL /* wrist_on, wrist_off, double_tap, charging_on, connected, … */, payload TEXT /* JSON */,
      UNIQUE (band_id, ts_ms, kind));
    CREATE TABLE alarm (id TEXT PRIMARY KEY, kind TEXT NOT NULL /* scheduled|webhook|relay */, label TEXT NOT NULL,
      schedule TEXT /* JSON rule */, rhythm TEXT NOT NULL /* JSON steps §9.2 */, channels TEXT NOT NULL /* ["phone","band"] */,
      enabled INTEGER NOT NULL, version INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL, deleted_at INTEGER,
      dirty INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE alarm_delivery (id TEXT PRIMARY KEY, alarm_id TEXT, dispatch_id TEXT, ts_ms INTEGER NOT NULL,
      channel TEXT NOT NULL, status TEXT NOT NULL, detail TEXT);
    CREATE TABLE sync_cursor (stream TEXT PRIMARY KEY /* hr_sample|rr_interval|minute_metric|band_event|alarm_delivery */,
      last_rowid INTEGER NOT NULL DEFAULT 0, last_success_at INTEGER);
    CREATE TABLE sync_batch_log (batch_id TEXT PRIMARY KEY, created_at INTEGER NOT NULL, rows INTEGER NOT NULL,
      status TEXT NOT NULL /* pending|sent|acked|rejected */, http_status INTEGER, error TEXT);
    CREATE TABLE raw_frame (rowid INTEGER PRIMARY KEY, ts_ms INTEGER NOT NULL, char TEXT NOT NULL, hex TEXT NOT NULL);
    """
    /// Migration v2, sleep-tracking foundation (history offload, PLAN.md 5.3.4). Additive.
    ///
    /// `historical_record` holds the strap's offloaded 1 Hz records (type 47, version 24), deduped
    /// by (band, timestamp) because the strap replays a batch until its ack lands. The scalar
    /// sensor bytes (SpO₂, skin temp, resp rate, PPG, signal quality) are stored raw: no
    /// raw-to-value mapping is verified yet (PLAN.md 5.5 non-goals). R-R lives in the row as a
    /// JSON array so a record stays one atomic row; the derivation for `sleep_session` reads whole
    /// records (Metrics `SleepDeriver`), not per-interval joins.
    ///
    /// `sleep_session` holds the derived nightly sessions (PLAN.md 8.1's night, extended by sleep
    /// detection). Sessions are keyed by (band, start) and rewritten on recompute, so a session
    /// that later records extend replaces its earlier partial self.
    static let v2 = """
    CREATE TABLE historical_record (rowid INTEGER PRIMARY KEY, band_id TEXT NOT NULL REFERENCES band(id),
      ts_ms INTEGER NOT NULL /* record unix seconds, in ms per PLAN.md 10.1 */, version INTEGER NOT NULL /* record layout version (frame seq) */,
      bpm INTEGER /* raw u8, 0 = no reading, stored NULL */, contact INTEGER /* 1 on-wrist, 0 off */,
      rr_ms TEXT /* JSON array of u16 ms */,
      ppg_green INTEGER, ppg_red_ir INTEGER, spo2_red INTEGER, spo2_ir INTEGER,
      skin_temp_raw INTEGER, resp_rate_raw INTEGER, signal_quality INTEGER,
      UNIQUE (band_id, ts_ms));
    CREATE INDEX historical_record_ts ON historical_record(ts_ms);
    CREATE TABLE sleep_session (rowid INTEGER PRIMARY KEY, band_id TEXT NOT NULL REFERENCES band(id),
      start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL, duration_s INTEGER NOT NULL,
      resting_hr REAL, rmssd_ms REAL, resp_rate_raw REAL, skin_temp_raw REAL,
      contact_fraction REAL NOT NULL, quality TEXT NOT NULL /* good|fair|poor */, record_count INTEGER NOT NULL,
      algo_version INTEGER NOT NULL, computed_at INTEGER NOT NULL,
      UNIQUE (band_id, start_ms));
    CREATE INDEX sleep_session_start ON sleep_session(start_ms);
    """
    /// Migration v3, advanced raw band data. Additive: nine nullable columns on `historical_record`
    /// for the fields the v2 ingest dropped — both gravity triplets (f32, in g) and the ambient-light
    /// and LED drive bytes (raw u16). Older rows keep NULLs, and the UNIQUE(band_id, ts_ms) dedup
    /// constraint from v2 is untouched (replayed batches still dedupe).
    static let v3 = """
    ALTER TABLE historical_record ADD COLUMN gravity_x REAL;
    ALTER TABLE historical_record ADD COLUMN gravity_y REAL;
    ALTER TABLE historical_record ADD COLUMN gravity_z REAL;
    ALTER TABLE historical_record ADD COLUMN gravity2_x REAL;
    ALTER TABLE historical_record ADD COLUMN gravity2_y REAL;
    ALTER TABLE historical_record ADD COLUMN gravity2_z REAL;
    ALTER TABLE historical_record ADD COLUMN ambient_drive INTEGER;
    ALTER TABLE historical_record ADD COLUMN led_drive1 INTEGER;
    ALTER TABLE historical_record ADD COLUMN led_drive2 INTEGER;
    """
    /// Migration v4, staged sleep hypnograms. Additive: one row per contiguous stage segment for a
    /// derived `sleep_session`, keyed conceptually by `(band_id, session_start_ms)` but not enforced
    /// as an SQL foreign key — derivation deletes and re-inserts a session's segments in the same
    /// transaction, and a session start is a natural key rather than a rowid.
    ///
    /// `algo_version` is `SleepStager.algoVersion`: it lets a future recompute detect segments written
    /// by an older recipe instead of trusting stale rows.
    static let v4 = """
    CREATE TABLE sleep_stage_segment (rowid INTEGER PRIMARY KEY, band_id TEXT NOT NULL REFERENCES band(id),
      session_start_ms INTEGER NOT NULL /* sleep_session.start_ms (natural key) */,
      start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL, stage TEXT NOT NULL /* wake|light|deep|rem */,
      algo_version INTEGER NOT NULL, computed_at INTEGER NOT NULL);
    CREATE INDEX sleep_stage_segment_session ON sleep_stage_segment(band_id, session_start_ms);
    """
    /// Migration v5, main sleep vs nap. Additive: `is_nap` is 1 for a daytime nap that passed the
    /// detector's daytime guard, 0 for the night's main sleep. Existing rows default to 0; the
    /// `SleepDeriver.algoVersion` bump re-derives them, which writes the real flag.
    static let v5 = """
    ALTER TABLE sleep_session ADD COLUMN is_nap INTEGER NOT NULL DEFAULT 0;
    """
    /// Migration v6, user corrections to detected sleep (the bed/wake retime and the deleted night).
    /// Additive. One row per corrected night, keyed by the night's DETECTED start: the derivation
    /// re-detects from raw records on every drain, so a correction lives here and is replayed onto
    /// each re-derivation instead of being written into `sleep_session`, which re-derivation replaces.
    ///
    /// `original_start_ms` / `original_end_ms` are the detected window the correction was made against
    /// (the overlap key that matches a later re-detection, whose onset drifts as data lands).
    /// `new_start_ms` / `new_end_ms` are the corrected bounds; a `dismiss` row has no new end and keeps
    /// `new_start_ms` equal to the original start. `kind` is `retime` or `dismiss`.
    static let v6 = """
    CREATE TABLE sleep_edit (rowid INTEGER PRIMARY KEY, band_id TEXT NOT NULL REFERENCES band(id),
      original_start_ms INTEGER NOT NULL, original_end_ms INTEGER NOT NULL,
      new_start_ms INTEGER NOT NULL, new_end_ms INTEGER /* NULL for dismiss */,
      kind TEXT NOT NULL CHECK (kind IN ('retime', 'dismiss')), created_at INTEGER NOT NULL,
      UNIQUE (band_id, original_start_ms));
    CREATE INDEX sleep_edit_new_start ON sleep_edit(band_id, new_start_ms);
    """
    /// Migration v7, nightly respiratory rate. Additive: `resp_rate_brpm` holds the session's respiratory rate
    /// in breaths/min, estimated from the R-R intervals (`SleepSession.respiratoryRateBrpm`). It is separate
    /// from `resp_rate_raw`, the raw byte that is a constant on this strap. Existing rows are NULL until the
    /// `SleepDeriver.algoVersion` bump re-derives them.
    static let v7 = """
    ALTER TABLE sleep_session ADD COLUMN resp_rate_brpm REAL;
    """
    /// Migration v8, medication profiles and dose overrides. Additive and local-only (no server sync).
    /// `medication` holds one row per profile. `schedule` and `weekdays` are JSON arrays (minutes of the
    /// local day; 1 = Sunday ... 7 = Saturday, `[]` = every day). Deletes are soft (`deleted_at`).
    /// `medication_dose_override` holds per-day corrections: `taken` rows carry `taken_at_ms`, `skipped`
    /// rows carry none. A day may have several `taken` rows. `local_day` is 'YYYY-MM-DD'.
    static let v8 = """
    CREATE TABLE medication (id TEXT PRIMARY KEY /* UUIDv7 */, name TEXT NOT NULL,
      med_class TEXT NOT NULL, formulation TEXT NOT NULL, onset_min INTEGER NOT NULL, duration_min INTEGER NOT NULL,
      schedule TEXT NOT NULL /* JSON array of minutes of day */, weekdays TEXT NOT NULL /* JSON array, [] = every day */,
      active INTEGER NOT NULL DEFAULT 1, updated_at INTEGER NOT NULL, deleted_at INTEGER);
    CREATE TABLE medication_dose_override (id TEXT PRIMARY KEY /* UUIDv7 */,
      medication_id TEXT NOT NULL REFERENCES medication(id), local_day TEXT NOT NULL,
      kind TEXT NOT NULL CHECK (kind IN ('taken', 'skipped')), taken_at_ms INTEGER,
      created_at INTEGER NOT NULL, CHECK ((kind = 'taken') = (taken_at_ms IS NOT NULL)));
    CREATE INDEX medication_dose_override_med_day ON medication_dose_override(medication_id, local_day);
    """
    /// Migration v9, activities (local only; not synced to the server). One row per workout, detected or recorded.
    /// `source` is `auto` (written by `detectActivities`) or `manual` (recorded or edited by the user). A row the user
    /// retypes or renames becomes `manual`, so detection never overwrites it. `deleted_at` is a tombstone: detection
    /// skips any span a tombstone covers, so a deleted auto activity does not come back. `zone_minutes` is a JSON array
    /// of six minute totals, indexed like `Strain.Score.zoneMinutes`. Strain is on the 0-21 display scale.
    /// Migration text is self-contained: the v8 medications migration is not referenced here.
    static let v9 = """
    CREATE TABLE activity (id TEXT PRIMARY KEY, band_id TEXT REFERENCES band(id),
      start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL,
      kind TEXT NOT NULL CHECK (kind IN ('run','walk','cycle','strength','hiit','yoga','sport','other')),
      source TEXT NOT NULL CHECK (source IN ('auto','manual')), name TEXT,
      strain REAL, avg_hr REAL, max_hr INTEGER, kcal REAL,
      zone_minutes TEXT NOT NULL DEFAULT '[]', algo_version INTEGER NOT NULL,
      updated_at INTEGER NOT NULL, deleted_at INTEGER);
    CREATE INDEX activity_start ON activity(start_ms);
    """
    /// Migration v10, the journal (morning check-in) and its seeded questions. Additive and local-only (no server
    /// sync). Migration v9 (activities) sits between v8 and v10;
    /// nothing here depends on it.
    ///
    /// `journal_question` holds the questions the check-in asks: `kind` is `yesno` (value 1 yes, 0 no) or `count`
    /// (value is a non-negative count). Built-ins are seeded with `built_in = 1` and cannot be deleted, only
    /// disabled. `journal_entry` holds one answer per (`local_day`, question). A missing row means unanswered.
    /// `local_day` is 'YYYY-MM-DD'.
    static let v10 = """
    CREATE TABLE journal_question (id TEXT PRIMARY KEY, label TEXT NOT NULL,
      kind TEXT NOT NULL CHECK (kind IN ('yesno', 'count')), built_in INTEGER NOT NULL DEFAULT 0,
      enabled INTEGER NOT NULL DEFAULT 1, sort INTEGER NOT NULL, updated_at INTEGER NOT NULL);
    INSERT INTO journal_question (id, label, kind, built_in, enabled, sort, updated_at) VALUES
      ('caffeine_after_2pm', 'Caffeine after 2 pm', 'yesno', 1, 1, 0, 0),
      ('alcohol', 'Alcohol', 'yesno', 1, 1, 1, 0),
      ('late_meal', 'Late meal (within 2 h of bed)', 'yesno', 1, 1, 2, 0),
      ('screens_in_bed', 'Screens in bed', 'yesno', 1, 1, 3, 0),
      ('hydrated', 'Hydrated', 'yesno', 1, 1, 4, 0),
      ('read_before_bed', 'Read before bed', 'yesno', 1, 1, 5, 0),
      ('sexual_activity', 'Sexual activity', 'yesno', 1, 1, 6, 0),
      ('felt_sick', 'Felt sick', 'yesno', 1, 1, 7, 0),
      ('high_stress_day', 'High stress day', 'yesno', 1, 1, 8, 0),
      ('nap', 'Nap', 'yesno', 1, 1, 9, 0);
    CREATE TABLE journal_entry (local_day TEXT NOT NULL, question_id TEXT NOT NULL REFERENCES journal_question(id),
      value INTEGER NOT NULL CHECK (value >= 0), updated_at INTEGER NOT NULL,
      PRIMARY KEY (local_day, question_id));
    """
    /// Migration v11, the per-day score cache behind every metric screen (`MetricSeries`). Local-only and derived:
    /// `Database.refreshDailyScores` rewrites a row from `dailyScores` and the single sources, after each history
    /// derivation and at launch. Nothing reads it except `metricDays` and `metricLatest`, so a row can always be
    /// rebuilt. `local_day` is 'YYYY-MM-DD'. Columns are nullable where the value can be missing for a day.
    /// `hr_avg`, `hr_min` and `hr_max` are the mean, lowest and highest of the day's minute averages (`minute_metric.hr_avg`).
    /// `recovery_calibrating` is 1 while the baseline is too thin to score. `asleep_sec`, `sleep_need_sec` and
    /// `sleep_debt_sec` are whole seconds. `strain` is WHOOP's 0 to 21 scale.
    static let v11 = """
    CREATE TABLE daily_score (local_day TEXT PRIMARY KEY, recovery REAL, recovery_calibrating INTEGER,
      strain REAL, sleep_performance REAL, asleep_sec INTEGER, sleep_need_sec INTEGER, sleep_debt_sec INTEGER,
      resting_hr REAL, rmssd_ms REAL, resp_rate REAL, stress_avg REAL, kcal REAL,
      hr_avg REAL, hr_min REAL, hr_max REAL, computed_at INTEGER NOT NULL);
    """
}
