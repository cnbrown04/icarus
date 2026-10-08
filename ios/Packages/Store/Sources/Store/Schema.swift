import GRDB

/// Migrations for the local store. Each migration is append-only (PLAN.md 10.2).
enum Schema {
    static func registerMigrations(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1") { db in
            try db.execute(sql: v1)
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
}
