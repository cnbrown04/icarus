# Icarus server

Needs Rust stable and Postgres 16. From `server/`:

    createdb icarus
    DATABASE_URL=postgres://postgres:postgres@localhost:5432/icarus cargo run -p icarus-server

Then `curl localhost:8080/healthz` (liveness) and `curl localhost:8080/readyz` (database and migrations). Set `ICARUS_BIND` to change the address.
