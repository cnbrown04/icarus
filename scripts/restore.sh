#!/usr/bin/env bash
# Restores an Icarus backup into an existing database, then runs a sanity query (docs/backup.md).
#
# Usage: TARGET_DATABASE_URL=postgres://... scripts/restore.sh backups/icarus-<stamp>.dump[.age|.gpg]
#
# Environment:
#   TARGET_DATABASE_URL  required. An existing database. Its public schema must be empty
#                        unless RESTORE_FORCE=1.
#   RESTORE_FORCE        set to 1 to drop and recreate the objects already in the target.
#   AGE_IDENTITY         needed for .age files: path to the age identity (private key) file.
#   GPG_HOME             optional. gpg home for .gpg files, when not the default.
set -euo pipefail

: "${TARGET_DATABASE_URL:?set TARGET_DATABASE_URL}"
if [[ $# -ne 1 ]]; then
  echo "usage: restore.sh <backup-file>" >&2
  exit 2
fi
file="$1"
if [[ ! -f "$file" ]]; then
  echo "restore: no such file: $file" >&2
  exit 2
fi
force="${RESTORE_FORCE:-0}"

existing="$(psql --no-psqlrc --tuples-only --no-align --dbname="$TARGET_DATABASE_URL" \
  --command="SELECT count(*) FROM pg_tables WHERE schemaname = 'public'")"
if [[ "$existing" != "0" && "$force" != "1" ]]; then
  echo "restore: the target already has $existing tables in public; use an empty database or RESTORE_FORCE=1" >&2
  exit 1
fi

restore_args=(--no-owner --no-acl --exit-on-error --dbname="$TARGET_DATABASE_URL")
if [[ "$force" == "1" ]]; then
  restore_args+=(--clean --if-exists)
fi

# pg_restore reads the custom-format dump from stdin, so decrypted data never touches disk.
case "$file" in
  *.age)
    : "${AGE_IDENTITY:?set AGE_IDENTITY to the age identity file for this backup}"
    age --decrypt --identity "$AGE_IDENTITY" "$file" | pg_restore "${restore_args[@]}"
    ;;
  *.gpg)
    gpg_args=(--batch --decrypt)
    if [[ -n "${GPG_HOME:-}" ]]; then
      gpg_args+=(--homedir "$GPG_HOME")
    fi
    gpg "${gpg_args[@]}" "$file" | pg_restore "${restore_args[@]}"
    ;;
  *)
    pg_restore "${restore_args[@]}" "$file"
    ;;
esac

# A restore that loads but has no migration history or no users is not a usable backup.
sanity="$(psql --no-psqlrc --tuples-only --no-align --dbname="$TARGET_DATABASE_URL" \
  --command="SELECT (SELECT count(*) FROM _sqlx_migrations WHERE success) || ' ' || (SELECT count(*) FROM users)")"
read -r migrations users <<<"$sanity"
if [[ "$migrations" -lt 1 || "$users" -lt 1 ]]; then
  echo "restore: sanity query failed (migrations=$migrations users=$users)" >&2
  exit 1
fi
echo "restore: sanity ok (migrations applied=$migrations, users=$users)" >&2
