# Icarus API contract v1

Source of truth for the server (`server/`), the website (`web/`) and the app (`ios/Packages/SyncKit`).
Derived from PLAN.md §10.3, §11, §12. If code and this file disagree, fix the code or update this file in the same commit.

## Conventions

- Base path `/v1`. JSON bodies, `Content-Type: application/json` unless stated.
- Times: RFC 3339 UTC strings with `Z` (e.g. `2026-10-07T14:30:00Z`) unless a field ends in `_ms` (epoch milliseconds, integer).
- Days: `YYYY-MM-DD` in the user's timezone (`users.tz`).
- IDs: UUID strings. Client-created rows (alarms, batches, devices' bands) use UUIDv7.
- Errors: RFC 9457 `application/problem+json`: `{ "type": "urn:icarus:problem:<slug>", "title": "...", "status": 400, "detail": "..." }`.
  Slugs used: `unauthorized`, `forbidden`, `not-found`, `validation`, `conflict`, `rate-limited`, `payload-too-large`,
  `pairing-code-invalid`, `signature-invalid`, `database-unavailable`, `migrations-pending`, `internal`.
- `409 conflict` bodies add `"current": <entity>`.
- Optimistic concurrency: mutable entities carry `version` (integer). Updates send header `If-Match: <version>`. Mismatch: 409.
  Missing `If-Match` on PATCH: 428 with slug `validation`.

## Auth

| Caller | How |
|---|---|
| Website | Cookie `icarus_session` (HttpOnly, Secure unless `ICARUS_INSECURE_COOKIES=1`, SameSite=Lax, 30-day sliding). Every non-GET request with cookie auth must send header `X-Icarus-CSRF: 1`, else 403 `forbidden`. |
| iOS app | `Authorization: Bearer <device token>` |
| Webhook senders | HMAC header or secret URL (see Webhook ingress) |

Routes accept either cookie or bearer unless the table says "web" (cookie only) or "app" (bearer only).

### Bootstrap user

No sign-up route. Create the single user with the binary:
`ICARUS_PASSWORD=... icarus-server create-user caleb@example.com` (prints the user id; fails if the email exists).

## Routes

### Health
- `GET /healthz` -> `{"status":"ok"}`
- `GET /readyz` -> `{"status":"ready"}` or 503 problem.

### Auth (web)
- `POST /v1/auth/login` `{ "email": "...", "password": "..." }` -> 204 + `Set-Cookie`. Bad credentials -> 401 `unauthorized`. 5 attempts/min/IP, then 429 `rate-limited`. (CSRF header not required on login.)
- `POST /v1/auth/logout` -> 204, clears cookie.
- `GET /v1/me` -> `Me`
- `PATCH /v1/me` (If-Match) body: any subset of `{ tz, formula_sex, birth_year, height_cm, weight_kg, hr_max }` -> `Me`
- `DELETE /v1/me` (web) `{ "confirm": "<the user's email>" }` -> 204. Deletes everything (cascade).

`Me`:
```json
{ "id": "uuid", "email": "a@b.c", "tz": "America/Chicago", "formula_sex": "male", "birth_year": 1995,
  "height_cm": 180.0, "weight_kg": 80.0, "hr_max": 190, "version": 3 }
```
Profile fields may be `null`.

### Devices and pairing
- `POST /v1/devices/pairing-codes` (web) -> `{ "code": "K7Q2M9XD", "qr_svg": "<svg ...>", "expires_at": "..." }`. Code: 8 chars from `ABCDEFGHJKMNPQRSTUVWXYZ23456789`, TTL 10 min, single use. QR encodes `icarus://pair?code=<code>&server=<PUBLIC_BASE_URL>`.
- `POST /v1/devices/pair` (no auth) `{ "code", "name", "model", "os_version", "app_version" }` -> 201 `{ "device_id": "uuid", "token": "<base64url 32 bytes>" }`. Bad/expired/used code -> 400 `pairing-code-invalid`.
- `GET /v1/devices` -> `{ "devices": [Device], "bands": [Band] }`
  - `Device`: `{ id, name, model, os_version, app_version, created_at, last_seen_at, revoked_at }`
  - `Band`: `{ id, name, firmware, created_at, last_seen_at }`
- `DELETE /v1/devices/{id}` (web) -> 204 (sets `revoked_at`; that token then gets 401).
- `PUT /v1/devices/me/push-token` (app) `{ "apns_token": "hex", "environment": "sandbox"|"production" }` -> 204.

### Sync (PLAN.md §11)
- `POST /v1/sync/batches` (app). Headers: `Idempotency-Key: <batch_id>`, optional `Content-Encoding: gzip`. Max 2 MB body after decompression, max 20,000 time-series rows.
  Body:
  ```json
  { "schema": 1, "batch_id": "uuid", "device_id": "uuid", "created_at": "...",
    "bands": [{ "id": "uuid", "name": "WHOOP 4.0", "firmware": "x" }],
    "hr": { "band_id": "uuid", "ts_ms": [1], "bpm": [60], "source": [1], "contact": [true] },
    "rr": { "band_id": "uuid", "ts_ms": [1], "seq": [0], "rr_ms": [1000.0], "accepted": [true] },
    "minute_metrics": [ { "minute_ms": 0, "hr_avg": 61.2, "hr_min": 58, "hr_max": 66, "hr_n": 60,
        "rmssd_ms": 42.1, "sdnn_ms": 50.3, "baevsky_sqrt": 9.1, "stress": 31, "stress_state": "value",
        "kcal": 1.4, "active_kcal": 0.2, "kcal_estimated": false, "algo_version": 1, "sync_rev": 1 } ],
    "events": [ { "band_id": "uuid", "ts_ms": 0, "kind": "wrist_off", "payload": {} } ],
    "alarm_deliveries": [ { "id": "uuid", "alarm_id": "uuid|null", "dispatch_id": "uuid|null", "ts_ms": 0,
        "channel": "phone"|"band", "status": "shown"|"ok"|"not_connected"|"disabled"|"failed", "detail": null } ],
    "cursors": { "hr_sample": 123, "rr_interval": 98 } }
  ```
  `hr`, `rr` may be `null`. Column arrays in one object must have equal length, else 400 `validation`.
  Response 200:
  ```json
  { "batch_id": "uuid", "duplicate": false, "server_time": "...",
    "counts": { "hr": {"inserted": 3600, "duplicate": 0}, "rr": {...}, "minute_metrics": {"upserted": 60, "stale": 0},
                "events": {...}, "alarm_deliveries": {...} } }
  ```
  Same `batch_id` again -> the stored counts with `"duplicate": true`.
- `GET /v1/sync/config?since=<int>` (app) -> `{ "alarms": [Alarm], "webhook_endpoints": [Hook], "profile": Me, "max_version": 1042, "server_time": "..." }`. Includes tombstoned alarms (`deleted_at` set) with `version > since`.
- `GET /v1/sync/state` -> `{ "server_time": "...", "last_batch_at": "...|null", "batches": [ { "id", "device_id", "received_at", "counts", "status" } ] }` (latest 50).

### Metrics (read)
- `GET /v1/metrics/hr?from=<rfc3339>&to=<rfc3339>&res=raw|1m|5m|1h` -> `{ "res": "1m", "points": [ { "t": "...", "avg": 61.2, "min": 58, "max": 66 } ] }`.
  `raw` allowed only for ranges <= 6 h (else 400). `1m`/`5m` read `minute_metrics` (ranges <= 14 d), `1h` aggregates minute metrics.
- `GET /v1/metrics/minutes?from&to` -> `{ "minutes": [ { "minute": "...", "hr_avg", "hr_min", "hr_max", "hr_n", "rmssd_ms", "sdnn_ms", "baevsky_sqrt", "stress", "stress_state", "kcal", "active_kcal", "kcal_estimated" } ] }` (range <= 14 d).
- `GET /v1/metrics/daily?from=YYYY-MM-DD&to=YYYY-MM-DD` -> `{ "days": [ { "day", "rhr", "hr_avg", "hr_max", "rmssd_night_ms", "stress_avg", "stress_high_minutes", "kcal_total", "kcal_active", "coverage" } ] }`.
- `GET /v1/metrics/live` -> `{ "bpm": 62, "ts": "..." }` (latest raw sample) or `{ "bpm": null, "ts": null }`.

### Alarms (PLAN.md §9)
`Rhythm` is either a built-in name (`"single"|"double"|"triple"|"long"|"ramp"|"sos"`) or an array of steps:
`[{ "type": "buzz", "preset": 2, "loops": 1 }, { "type": "pause", "ms": 300 }]`. Max 10 steps; total time <= 30 s, counting each buzz loop as 1 s.

`Schedule` (kind `scheduled` only): `{ "time": "06:30", "weekdays": [1,2,3,4,5] }` (ISO weekday 1 = Monday; empty = one-off next occurrence).

`Alarm`:
```json
{ "id": "uuid", "kind": "scheduled"|"webhook"|"relay", "label": "Wake up", "schedule": Schedule|null,
  "rhythm": Rhythm, "channels": ["phone","band"], "enabled": true, "version": 7,
  "updated_at": "...", "deleted_at": null }
```
- `GET /v1/alarms` -> `{ "alarms": [Alarm] }` (not deleted)
- `POST /v1/alarms` body Alarm without `version/updated_at/deleted_at` (`id` optional) -> 201 Alarm
- `PATCH /v1/alarms/{id}` (If-Match) partial -> Alarm
- `DELETE /v1/alarms/{id}` (If-Match optional) -> 204 (soft delete, bumps version)
- `POST /v1/alarms/{id}/test` -> 202 `{ "dispatch_id": "uuid" }`
- `GET /v1/alarms/pending` (app) -> `{ "dispatches": [Dispatch] }` (unacked, last 10 min)
- `GET /v1/alarm-dispatches?limit=50` -> `{ "dispatches": [Dispatch] }`
- `POST /v1/alarm-dispatches/{id}/ack` (app) `{ "phone": "shown"|"failed", "band": "ok"|"not_connected"|"disabled"|"failed", "detail": null }` -> 204

`Dispatch`: `{ "id", "alarm_id", "delivery_id", "created_at", "attempts", "phone_status", "band_status", "acked_at", "status": "pending"|"sent"|"acked"|"unacked"|"failed", "message": "Front door opened"|null, "rhythm": Rhythm }`

### Webhook management (web)
`Hook`: `{ "id", "slug", "label", "alarm_id", "auth_mode": "hmac"|"secret_url", "rate_limit_per_min": 10, "enabled": true, "url": "<PUBLIC_BASE_URL>/v1/hooks/<slug>", "created_at", "last_triggered_at", "version" }`
- `GET /v1/hooks` -> `{ "hooks": [Hook] }`
- `POST /v1/hooks` `{ "label", "alarm_id", "auth_mode", "rate_limit_per_min"? }` -> 201 `Hook` + `"secret": "<base64url 32 bytes>"` (shown once). For `secret_url`, `url` includes `/<secret>`.
- `PATCH /v1/hooks/{id}` `{ label?, alarm_id?, enabled?, rate_limit_per_min? }` -> Hook
- `DELETE /v1/hooks/{id}` -> 204
- `POST /v1/hooks/{id}/rotate-secret` -> `{ "secret": "..." }`
- `GET /v1/hooks/{id}/deliveries?cursor=<opaque>` -> `{ "deliveries": [ { "id", "received_at", "status": "accepted"|"rejected"|"rate_limited"|"duplicate", "signature_valid", "dispatch": Dispatch|null } ], "next_cursor": "...|null" }`

### Webhook ingress (public, PLAN.md §12.4)
- `POST /v1/hooks/{slug}` with header `X-Icarus-Signature: t=<unix>,v1=<hex(HMAC_SHA256(secret, t + "." + raw_body))>`. `|now - t| > 300 s` -> 401 `signature-invalid`.
- `POST /v1/hooks/{slug}/{secret}` (only if the endpoint's auth_mode is `secret_url`).
- Body optional JSON `{ "idempotency_key"?, "rhythm"?, "message"? (<= 120 chars), "channels"? }`, max 16 KB.
- Success: 202 `{ "dispatch_id": "uuid" }`. Duplicate key: 200 `{ "duplicate": true, "dispatch_id": "uuid" }`. Rate limited: 429.
- Raw bodies are never stored or logged.

### WHOOP (Phase 7, optional; PLAN.md §6.3, §12.6)
- `GET /v1/integrations/whoop` -> `{ "connected": bool, "scopes": [..], "connected_at": "...|null", "last_webhook_at": "...|null" }`
- `GET /v1/integrations/whoop/connect` (web) -> 302 to WHOOP auth URL (8-char state).
- `GET /v1/integrations/whoop/callback?code&state` -> 302 to `/integrations/whoop`.
- `POST /v1/integrations/whoop/webhook` (WHOOP signature) -> 204.
- `GET /v1/integrations/whoop/summary?day=YYYY-MM-DD` -> live-fetched `{ "recovery_score", "hrv_rmssd_milli", "resting_heart_rate", "strain", "kilojoule", "sleep_performance" }` (any may be null). Not stored.
- `DELETE /v1/integrations/whoop` -> 204 (revoke + delete tokens).
- Disabled (404 `not-found`) unless `WHOOP_CLIENT_ID` and `WHOOP_CLIENT_SECRET` are set.

### Data rights
- `GET /v1/export` (web) -> `application/x-ndjson` stream; one JSON object per line with a `"kind"` field (`me`, `device`, `band`, `hr`, `rr`, `minute_metric`, `daily_summary`, `event`, `alarm`, `hook`, `dispatch`).

## Server environment
`DATABASE_URL`, `ICARUS_BIND` (default `0.0.0.0:8080`), `PUBLIC_BASE_URL` (default `http://localhost:8080`),
`ICARUS_ENC_KEY` (base64 32 bytes; required for hooks/WHOOP), `ICARUS_WEB_DIR` (static web build, default `../web/dist`),
`ICARUS_INSECURE_COOKIES=1` (local dev/tests only), `APNS_KEY_P8`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC`
(APNs disabled with a log line when unset), `WHOOP_CLIENT_ID`, `WHOOP_CLIENT_SECRET`.

## Decisions made during implementation (2026-10-08)
- Hooks are hard-deleted. `GET /v1/sync/config` always returns the full current hook list; the app replaces its copy instead of applying tombstones.
- `alarm_dispatches` gained `message`, `rhythm`, `channels`, `last_attempt_at`, `ack_detail` (migration 0003). `phone_status` values: `sent`, `apns_disabled`, `retrying`, `no_device`, `apns_error`, plus the ack values.
- HMAC key = the UTF-8 bytes of the base64url secret string as shown to the user.
- Secret-URL deliveries without `idempotency_key` are not deduplicated (no timestamp to hash).
- Rejected, rate-limited and duplicate ingress requests are recorded as delivery rows (no body); retention removes them after 90 days.
- `/v1/metrics/hr` requires `res`; `1h` is capped at 14 days like `1m`/`5m`; daily ranges are capped at 3660 days.
- Export lines name the inner kinds `event_kind` and `alarm_kind`; hook secrets are never exported.
- Ingress timeout (2 s) returns an empty 408. Missing `ICARUS_ENC_KEY` returns 503 `internal`.
- Batch row-limit overflow returns 413 `payload-too-large`. `Idempotency-Key` must equal `batch_id`.
- `PATCH /v1/hooks/{id}` requires `If-Match` like every PATCH.
- WHOOP routes use the web session only. The callback needs no cookie (the stored state names the user).
- WHOOP: not connected, or an expired/revoked WHOOP sign-in, returns 404 `not-found` with a detail (never 401, which would sign the web app out). Upstream failure returns 502 `internal`; local or WHOOP rate limit returns 429 `rate-limited`.
- WHOOP summary defaults `day` to today in `users.tz` and is sent with `Cache-Control: no-store`.
- WHOOP webhook rows are stored only for a connected WHOOP user and pruned 7 days after processing. No replay window is applied (WHOOP retries for about an hour).
