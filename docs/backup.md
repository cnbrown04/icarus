# Backups and restore

PLAN.md §18: nightly encrypted logical backups, 30-day retention, a restore test every quarter.
PLAN.md §19 Phase 8 exit criterion: the restore drill passes.

The backup is the Postgres database. It holds accounts, sessions, time series, alarms, and the
encrypted webhook secrets and WHOOP tokens.

**The `ICARUS_ENC_KEY` is not in the backup.** Store it separately (see docs/deploy.md). Without it,
a restored database cannot open hook secrets or WHOOP tokens.

## Scripts

All three are in `scripts/` and need `pg_dump`, `pg_restore` and `psql` 16 or newer on the host.

| Script | Purpose | Key inputs |
|---|---|---|
| `scripts/backup.sh` | `pg_dump -Fc` to `icarus-<UTC time>.dump`, optionally encrypted, then prunes files older than 30 days. Prints the path. | `DATABASE_URL`, `BACKUP_DIR`, `BACKUP_AGE_RECIPIENT` or `BACKUP_GPG_RECIPIENT`, `BACKUP_RETENTION_DAYS` (30) |
| `scripts/restore.sh` | Restores a dump into an empty database, then checks that migrations and users are present. | `TARGET_DATABASE_URL`, `AGE_IDENTITY` for `.age` files, `RESTORE_FORCE=1` to overwrite |
| `scripts/restore-drill.sh` | Backs up a seeded database, restores into a fresh one, and compares the row count of every table. Drops the scratch database afterwards. | `SOURCE_DATABASE_URL`, `ADMIN_DATABASE_URL`, `DRILL_KEEP=1` to keep it |

Encryption uses [age](https://age-encryption.org). Create a key pair with `age-keygen -o icarus-backup.key`.
Put the public key (`age1...`) in `BACKUP_AGE_RECIPIENT` on the server. Keep `icarus-backup.key` off the
server, for example in a password manager. Without that file, the backups cannot be read.

## Nightly backup

If the host can reach Postgres directly (a managed database, or a published port):

```sh
DATABASE_URL=postgres://icarus:...@127.0.0.1:5432/icarus \
BACKUP_DIR=/var/backups/icarus \
BACKUP_AGE_RECIPIENT=age1... \
/opt/icarus/scripts/backup.sh
```

For the Compose database, which the shipped `docker-compose.yml` does not publish, dump inside its
container. This is the same format and the same retention:

```sh
cd /opt/icarus
out="backups/icarus-$(date -u +%Y%m%dT%H%M%SZ).dump.age"
mkdir -p backups && chmod 700 backups
docker compose exec -T db pg_dump -Fc --no-owner --no-acl -U icarus icarus \
  | age -r "$AGE_RECIPIENT" -o "$out"
find backups -maxdepth 1 -name 'icarus-*.dump*' -mtime +30 -delete
```

Run it from cron or a systemd timer at night. Neither is in the repo yet.

## Restore

Restore into a new, empty database. `restore.sh` refuses a database that already has tables, unless
`RESTORE_FORCE=1` is set.

```sh
createdb -h 127.0.0.1 -U postgres icarus_restore
AGE_IDENTITY=icarus-backup.key \
TARGET_DATABASE_URL=postgres://postgres@127.0.0.1:5432/icarus_restore \
scripts/restore.sh backups/icarus-20261008T031500Z.dump.age
```

Into a fresh database in the Compose stack:

```sh
docker compose exec db createdb -U icarus icarus_restore
age --decrypt -i icarus-backup.key backups/icarus-<stamp>.dump.age \
  | docker compose exec -T db pg_restore -U icarus -d icarus_restore --no-owner --no-acl --exit-on-error
```

To switch to the restored data, stop the server, rename the databases with `ALTER DATABASE`, and start
the server again. Keep the old database until the restored one has been checked.

Restore into the live database only after stopping the server (`docker compose stop server`). Start it
again afterwards. It runs any pending migrations on start.

## Restore drill

Run the drill once per quarter and after any change to the backup scripts. It needs a seeded source
database. The seed is `scripts/drill-seed.sql`, which expects the server to have applied its migrations
and created the user:

```sh
ADMIN=postgres://postgres@127.0.0.1:5444
psql "$ADMIN/postgres" -c 'CREATE DATABASE icarus_drill_src'
ICARUS_PASSWORD='<12+ characters>' DATABASE_URL="$ADMIN/icarus_drill_src" \
  cargo run -p icarus-server -- create-user caleb@example.com
psql "$ADMIN/icarus_drill_src" -v ON_ERROR_STOP=1 -f scripts/drill-seed.sql

SOURCE_DATABASE_URL="$ADMIN/icarus_drill_src" ADMIN_DATABASE_URL="$ADMIN/postgres" \
  scripts/restore-drill.sh
```

The drill exits 1 if any table's count differs. To drill against production, take a copy of the
latest backup into a scratch server and run the same script there. Do not run it against the live
database.

### Recorded run: 2026-10-08

Local Postgres 16.15 on port 5444. Seeded with `scripts/drill-seed.sql` on one user, with migrations
applied by `icarus-server create-user`. Output of `scripts/restore-drill.sh`:

```
drill: backing up the source
backup: wrote /tmp/tmp.VWgs69YquH/icarus-20261008T065049Z.dump
backup: pruned files older than 30 days
drill: creating icarus_drill_20261008065049_2315 and restoring
restore: sanity ok (migrations applied=4, users=1)
drill: comparing row counts
table                          source     restored  result
_sqlx_migrations                    4            4  ok
alarm_deliveries                    1            1  ok
alarm_dispatches                    1            1  ok
alarms                              1            1  ok
band_events                         1            1  ok
bands                               1            1  ok
daily_summaries                     7            7  ok
devices                             1            1  ok
hr_samples                       2000         2000  ok
hr_samples_default               2000         2000  ok
minute_metrics                   1440         1440  ok
oauth_states                        0            0  ok
pairing_codes                       0            0  ok
push_tokens                         0            0  ok
rr_intervals                      500          500  ok
rr_intervals_default              500          500  ok
sessions                            0            0  ok
sync_batches                        1            1  ok
users                               1            1  ok
webhook_deliveries                  1            1  ok
webhook_endpoints                   1            1  ok
whoop_connections                   0            0  ok
whoop_webhook_events                0            0  ok
drill: PASSED, every table matches
```

Partitioned tables appear twice, once as the parent and once per partition. Both sides are counted the
same way, so this does not affect the comparison.

The drill has not been run against a real backup from the Compose deployment yet. That is the first
step before the 30-day soak in PLAN.md §19 Phase 8.
