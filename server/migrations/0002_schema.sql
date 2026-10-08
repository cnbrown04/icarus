-- PLAN.md §10.3 server schema, minus the Phase 7 WHOOP tables.
-- Deviations, all needed for the contract or for DELETE /v1/me to cascade:
--   * alarm_deliveries: carried by sync batches (api-contract.md) but absent from §10.3.
--   * ON DELETE CASCADE on cross references (sync_batches.device_id, alarm_dispatches.alarm_id,
--     webhook_endpoints.alarm_id) and FKs from the time-series tables to bands.

CREATE TABLE users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email citext UNIQUE NOT NULL,
  password_hash text NOT NULL, -- argon2id
  tz text NOT NULL DEFAULT 'America/Chicago',
  formula_sex text CHECK (formula_sex IN ('male', 'female')),
  birth_year smallint,
  height_cm real,
  weight_kg real,
  hr_max smallint,
  version bigint NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE sessions (
  id bytea PRIMARY KEY, -- sha256(cookie token)
  user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  user_agent text,
  ip inet
);
CREATE INDEX ON sessions (user_id);

CREATE TABLE devices (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE,
  name text NOT NULL,
  model text,
  os_version text,
  app_version text,
  token_hash bytea UNIQUE NOT NULL, -- sha256(token)
  created_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz,
  revoked_at timestamptz
);
CREATE INDEX ON devices (user_id);

CREATE TABLE pairing_codes (
  code_hash bytea PRIMARY KEY, -- sha256(code)
  user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE,
  expires_at timestamptz NOT NULL,
  used_at timestamptz
);

CREATE TABLE bands (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE,
  name text,
  firmware text,
  created_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz
);
CREATE INDEX ON bands (user_id);

-- Time series: monthly range partitions. icarus-jobs creates the current and next month;
-- hr_samples_default and rr_intervals_default catch anything else so inserts never fail.
CREATE TABLE hr_samples (
  band_id uuid NOT NULL REFERENCES bands ON DELETE CASCADE,
  ts timestamptz NOT NULL,
  bpm smallint NOT NULL CHECK (bpm BETWEEN 20 AND 250),
  source smallint NOT NULL,
  contact boolean,
  batch_id uuid NOT NULL,
  PRIMARY KEY (band_id, ts, source)
) PARTITION BY RANGE (ts);
CREATE INDEX ON hr_samples USING brin (ts);
CREATE TABLE hr_samples_default PARTITION OF hr_samples DEFAULT;

CREATE TABLE rr_intervals (
  band_id uuid NOT NULL REFERENCES bands ON DELETE CASCADE,
  ts timestamptz NOT NULL,
  seq smallint NOT NULL,
  rr_ms real NOT NULL,
  accepted boolean NOT NULL,
  batch_id uuid NOT NULL,
  PRIMARY KEY (band_id, ts, seq)
) PARTITION BY RANGE (ts);
CREATE INDEX ON rr_intervals USING brin (ts);
CREATE TABLE rr_intervals_default PARTITION OF rr_intervals DEFAULT;

CREATE TABLE minute_metrics (
  user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE,
  minute timestamptz NOT NULL,
  hr_avg real,
  hr_min smallint,
  hr_max smallint,
  hr_n smallint,
  rmssd_ms real,
  sdnn_ms real,
  baevsky_sqrt real,
  stress smallint,
  stress_state text,
  kcal real,
  active_kcal real,
  kcal_estimated boolean,
  algo_version smallint NOT NULL,
  origin text NOT NULL DEFAULT 'device', -- device|server_recompute
  sync_rev integer NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, minute)
);

CREATE TABLE daily_summaries (
  user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE,
  day date NOT NULL,
  rhr smallint,
  hr_avg real,
  hr_max smallint,
  rmssd_night_ms real,
  stress_avg real,
  stress_high_minutes integer,
  kcal_total real,
  kcal_active real,
  coverage real,
  algo_version smallint NOT NULL,
  computed_at timestamptz NOT NULL,
  PRIMARY KEY (user_id, day)
);

CREATE TABLE band_events (
  band_id uuid NOT NULL REFERENCES bands ON DELETE CASCADE,
  ts timestamptz NOT NULL,
  kind text NOT NULL,
  payload jsonb,
  batch_id uuid NOT NULL,
  PRIMARY KEY (band_id, ts, kind)
);

CREATE TABLE sync_batches (
  id uuid PRIMARY KEY, -- client batch_id = idempotency key
  device_id uuid NOT NULL REFERENCES devices ON DELETE CASCADE,
  received_at timestamptz NOT NULL DEFAULT now(),
  payload_sha256 bytea NOT NULL,
  schema_version smallint NOT NULL,
  counts jsonb NOT NULL,
  status text NOT NULL
);
CREATE INDEX ON sync_batches (device_id, received_at);

-- Mutable configuration. Server-assigned versions for config sync (PLAN.md §11.4).
CREATE SEQUENCE entity_version_seq;
CREATE TABLE alarms (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE,
  kind text NOT NULL CHECK (kind IN ('scheduled', 'webhook', 'relay')),
  label text NOT NULL,
  schedule jsonb,
  rhythm jsonb NOT NULL,
  channels text[] NOT NULL,
  enabled boolean NOT NULL DEFAULT true,
  version bigint NOT NULL DEFAULT nextval('entity_version_seq'),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz
);
CREATE INDEX ON alarms (user_id, version);

CREATE TABLE webhook_endpoints (
  id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE,
  slug text UNIQUE NOT NULL, -- random 22 chars
  label text NOT NULL,
  alarm_id uuid REFERENCES alarms ON DELETE CASCADE,
  auth_mode text NOT NULL CHECK (auth_mode IN ('hmac', 'secret_url')),
  secret_ciphertext bytea NOT NULL, -- AES-256-GCM
  rate_limit_per_min smallint NOT NULL DEFAULT 10,
  enabled boolean NOT NULL DEFAULT true,
  version bigint NOT NULL DEFAULT nextval('entity_version_seq'),
  created_at timestamptz NOT NULL DEFAULT now(),
  last_triggered_at timestamptz
);
CREATE INDEX ON webhook_endpoints (user_id, version);

CREATE TABLE webhook_deliveries (
  id uuid PRIMARY KEY,
  endpoint_id uuid NOT NULL REFERENCES webhook_endpoints ON DELETE CASCADE,
  received_at timestamptz NOT NULL DEFAULT now(),
  idempotency_key text NOT NULL,
  signature_valid boolean NOT NULL,
  status text NOT NULL CHECK (status IN ('accepted', 'rejected', 'rate_limited', 'duplicate')),
  request_meta jsonb, -- never the raw body
  UNIQUE (endpoint_id, idempotency_key)
);

CREATE TABLE alarm_dispatches (
  id uuid PRIMARY KEY,
  alarm_id uuid REFERENCES alarms ON DELETE CASCADE,
  delivery_id uuid REFERENCES webhook_deliveries ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  attempts smallint NOT NULL DEFAULT 0,
  apns_ids text[],
  phone_status text,
  band_status text,
  acked_at timestamptz,
  status text NOT NULL
);

-- Not in §10.3. Written by sync batches (api-contract.md, PLAN.md §10.2 alarm_delivery).
CREATE TABLE alarm_deliveries (
  id uuid PRIMARY KEY, -- client-generated
  user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE,
  batch_id uuid NOT NULL,
  alarm_id uuid,
  dispatch_id uuid,
  ts timestamptz NOT NULL,
  channel text NOT NULL CHECK (channel IN ('phone', 'band')),
  status text NOT NULL CHECK (status IN ('shown', 'ok', 'not_connected', 'disabled', 'failed')),
  detail text
);
CREATE INDEX ON alarm_deliveries (user_id, ts);

CREATE TABLE push_tokens (
  device_id uuid PRIMARY KEY REFERENCES devices ON DELETE CASCADE,
  apns_token text NOT NULL,
  environment text NOT NULL CHECK (environment IN ('sandbox', 'production')),
  updated_at timestamptz NOT NULL DEFAULT now()
);
