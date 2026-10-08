-- Phase 7: optional WHOOP integration (PLAN.md §10.3, §6.3, §12.6). Tokens and webhook trace ids only.
-- WHOOP payloads (recovery, cycles, sleep) are never stored.
CREATE TABLE whoop_connections (user_id uuid PRIMARY KEY REFERENCES users ON DELETE CASCADE,
  whoop_user_id bigint UNIQUE NOT NULL, scopes text[] NOT NULL, access_token_ct bytea NOT NULL,
  refresh_token_ct bytea NOT NULL, expires_at timestamptz NOT NULL, refresh_lock_until timestamptz,
  created_at timestamptz NOT NULL DEFAULT now());

CREATE TABLE whoop_webhook_events (trace_id text PRIMARY KEY, whoop_user_id bigint NOT NULL, type text NOT NULL,
  object_id text NOT NULL, received_at timestamptz NOT NULL DEFAULT now(), processed_at timestamptz);
CREATE INDEX whoop_webhook_events_user_idx ON whoop_webhook_events (whoop_user_id, received_at DESC);
CREATE INDEX whoop_webhook_events_open_idx ON whoop_webhook_events (received_at) WHERE processed_at IS NULL;

-- OAuth `state` values for the connect flow. Single use, valid for 10 minutes (checked on use).
CREATE TABLE oauth_states (state text PRIMARY KEY CHECK (char_length(state) = 8),
  user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE, created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX oauth_states_created_idx ON oauth_states (created_at);
