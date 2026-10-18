# Deploying Icarus

One image (`Dockerfile`) holds the server and the website. `docker-compose.yml` runs it with Postgres 17.
Host choice is open (PLAN.md §20 Q6: Fly.io, Railway, a VPS, or a home server behind a tunnel). This guide
assumes any Linux host with Docker Compose v2, a DNS name, and a reverse proxy for TLS. The host is not
chosen yet. Whether to use TimescaleDB is also open (§20 Q6). The compose file uses plain Postgres 17.

## Environment

Set these in `.env` next to `docker-compose.yml`. Never commit that file.

| Variable | Required | Notes |
|---|---|---|
| `POSTGRES_PASSWORD` | yes | Password for the `icarus` database user. |
| `ICARUS_ENC_KEY` | yes | Base64 for 32 bytes. Seals webhook secrets and WHOOP tokens. |
| `PUBLIC_BASE_URL` | yes in production | The public HTTPS URL, for example `https://icarus.example.com`. Used in hook URLs, the pairing QR code and the WHOOP redirect. |
| `ICARUS_INSECURE_COOKIES` | no | Leave unset or `0`. `1` drops `Secure` from the session cookie, for local use only. |
| `APNS_KEY_P8`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC` | for push | All four, or none. Without them alarms are queued and recorded as `apns_disabled`. |
| `WHOOP_CLIENT_ID`, `WHOOP_CLIENT_SECRET` | no | Both or neither. |

The image sets `ICARUS_BIND=0.0.0.0:8080`, `ICARUS_WEB_DIR=/app/web` and `RUST_LOG=info`.

Generate the encryption key once:

```sh
openssl rand -base64 32
```

Store a copy somewhere other than the server. Changing the key later makes stored hook secrets and WHOOP
tokens unreadable. There is no rotation command yet.

## Two edits to docker-compose.yml

The shipped file needs two changes for a reverse-proxy deployment:

1. Under `server: environment:` add `ICARUS_TRUST_PROXY: 1`. Without it, every client looks like the
   proxy's address, so the per-IP webhook limit (60/min) is shared by all senders.
2. Change `ports: - "8080:8080"` to `- "127.0.0.1:8080:8080"`. Then only the proxy on this host can reach
   the server, and the proxy's `X-Forwarded-For` cannot be spoofed.

Only set `ICARUS_TRUST_PROXY` when the server is reachable only through the proxy.

## Start

```sh
docker compose up -d --build
curl -fsS http://127.0.0.1:8080/readyz
```

`readyz` answers `{"status":"ready"}` once the database answers and migrations are applied. Migrations run
at every start, so the same command also upgrades an existing install. Take a backup first (docs/backup.md).

Create the single user. The password must be at least 12 characters:

```sh
ICARUS_PASSWORD='<12+ characters>' docker compose exec -e ICARUS_PASSWORD server \
  /app/icarus-server create-user caleb@example.com
```

It prints the user id. It fails if the email already exists.

## TLS with Caddy

Caddy gets and renews the certificate. Save as `/etc/caddy/Caddyfile` and reload Caddy:

```
icarus.example.com {
    encode gzip
    reverse_proxy 127.0.0.1:8080 {
        flush_interval -1
    }
}
```

`flush_interval -1` sends the NDJSON export as it is produced. The server sends `Strict-Transport-Security`
itself once `PUBLIC_BASE_URL` starts with `https://`.

## APNs key

1. In the Apple Developer account, open Certificates, Identifiers & Profiles, then Keys. Create a key with
   Apple Push Notifications service enabled. Download the `.p8` file. Apple lets you download it once.
2. `APNS_KEY_ID` is the key id shown on that page. `APNS_TEAM_ID` is the team id from the membership page.
   `APNS_TOPIC` is the app's bundle id.
3. `APNS_KEY_P8` takes the PEM text itself. Put the whole file in `.env`, inside double quotes, with its
   line breaks kept. Compose's handling of multi-line values is not tested here. Check the result with
   `docker compose config | grep APNS_KEY_P8`, and confirm `docker compose logs server` shows no
   "APNs disabled" line after a restart.

The app chooses sandbox or production per device token, so one key serves both.

## WHOOP (optional)

Create a WHOOP developer app. Its redirect URI must be exactly `PUBLIC_BASE_URL` followed by
`/v1/integrations/whoop/callback`. Set `WHOOP_CLIENT_ID` and `WHOOP_CLIENT_SECRET`, then restart. Until both
are set, every `/v1/integrations/whoop` route returns 404. Check PLAN.md §6.2 and §6.3 for what the WHOOP
terms allow you to store.

## Operations

- Logs: `docker compose logs -f server`. JSON lines. Health values are never logged.
- Stop: `docker compose down`. The `pgdata` volume is kept. `docker compose down -v` deletes all data.
- Backups and restore: docs/backup.md.

## Performance

Measured with `cargo test -p icarus-api --test perf -- --ignored --nocapture` (the test is ignored by
default). It seeds one user with 1 year of `minute_metrics` (525,600 rows), 1 year of `daily_summaries`
(365 rows), and 7 days of raw `hr_samples` at 1 Hz (about 605,000 rows), then calls each read the web
pages make through the full router with cookie auth. Each route runs once to warm up, then 5 timed runs.
The test fails if a median exceeds 1 s, which is the PLAN.md §19 Phase 8 budget.

Run on 2026-10-08: local Postgres 16.15, an unoptimised (dev profile) build, a shared VM.

| Route | Median ms | Max ms |
|---|---|---|
| `/v1/metrics/hr` 6 h, `res=raw` | 199.7 | 273.4 |
| `/v1/metrics/hr` 24 h, `res=1m` | 13.8 | 15.5 |
| `/v1/metrics/hr` 7 d, `res=5m` | 22.1 | 22.8 |
| `/v1/metrics/minutes` 24 h | 28.9 | 31.4 |
| `/v1/metrics/daily` 365 d | 7.9 | 8.1 |
| `/v1/metrics/live` | 44.6 | 51.8 |

No route exceeds the 300 ms local target. `hr` 6 h raw is the closest, at up to 273 ms, and it is the
first place to look if the numbers rise. No index or query change was made. Re-run the test after any
change to the metrics queries or the schema.
