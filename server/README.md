# Icarus server

Needs Rust stable and Postgres 16 or newer. From `server/`:

    createdb icarus
    DATABASE_URL=postgres://postgres:postgres@localhost:5432/icarus cargo run -p icarus-server

Then `curl localhost:8080/healthz` (liveness) and `curl localhost:8080/readyz` (database and migrations).

Create the single user (prints the user id; fails if the email exists or the password is under 12 characters):

    ICARUS_PASSWORD='...' DATABASE_URL=... cargo run -p icarus-server -- create-user caleb@example.com

Environment (see `shared/api-contract.md`):

| Variable | Default | Notes |
|---|---|---|
| `DATABASE_URL` | none, required | Postgres 16 or newer. |
| `ICARUS_BIND` | `0.0.0.0:8080` | Listen address. |
| `PUBLIC_BASE_URL` | `http://localhost:8080` | Base of hook URLs and the pairing QR code. |
| `ICARUS_WEB_DIR` | `../web/dist` | Static web build, served only if the directory exists. |
| `ICARUS_INSECURE_COOKIES` | unset | `1` drops `Secure` from the session cookie. Local dev only. |
| `ICARUS_TRUST_PROXY` | unset | `1` takes the client IP from `X-Forwarded-For` for rate limits. |
| `ICARUS_ENC_KEY` | unset | Base64 for 32 bytes. Encrypts webhook secrets (AES-256-GCM). Without it, hook routes answer 503 and a warning is logged at startup. Generate with `head -c 32 /dev/urandom \| base64`. |
| `APNS_KEY_P8` | unset | The `.p8` key itself, or a path to it. |
| `APNS_KEY_ID` | unset | Key id from the Apple developer account. |
| `APNS_TEAM_ID` | unset | Team id. |
| `APNS_TOPIC` | unset | The app's bundle id. |

APNs needs all four `APNS_*` values. Without them the server logs `APNs disabled` at startup, still queues
alarm dispatches, and records `phone_status = apns_disabled`. Sandbox or production is chosen per device token.

Background jobs: partitions and daily summaries run at startup and daily. Retention runs with them: raw
heart-rate and R-R partitions older than 400 days are dropped, and webhook deliveries older than 90 days are
deleted. The alarm dispatcher listens on Postgres `NOTIFY` and sweeps every 15 s.

Webhook signatures: `X-Icarus-Signature: t=<unix>,v1=<hex HMAC-SHA256(secret, t "." body)>`. The HMAC key is the
UTF-8 bytes of the secret string shown once when the hook is created.

Partitions for `hr_samples` and `rr_intervals` are created at startup and daily. Daily summaries are recomputed
after each sync batch commits and again daily for the last three local days.
