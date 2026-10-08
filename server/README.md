# Icarus server

Needs Rust stable and Postgres 16 or newer. From `server/`:

    createdb icarus
    DATABASE_URL=postgres://postgres:postgres@localhost:5432/icarus cargo run -p icarus-server

Then `curl localhost:8080/healthz` (liveness) and `curl localhost:8080/readyz` (database and migrations).

Create the single user (prints the user id; fails if the email exists or the password is under 12 characters):

    ICARUS_PASSWORD='...' DATABASE_URL=... cargo run -p icarus-server -- create-user caleb@example.com

Environment (see `shared/api-contract.md`): `ICARUS_BIND` (default `0.0.0.0:8080`), `PUBLIC_BASE_URL`,
`ICARUS_WEB_DIR` (default `../web/dist`, served only if it exists), `ICARUS_INSECURE_COOKIES=1` (local dev only,
drops `Secure`), `ICARUS_TRUST_PROXY=1` (take the client IP from `X-Forwarded-For` for rate limits).

Partitions for `hr_samples` and `rr_intervals` are created at startup and daily. Daily summaries are recomputed
after each sync batch commits and again daily for the last three local days.
