#!/usr/bin/env bash
# Logical backup of the Icarus database (PLAN.md §18, docs/backup.md).
#
# Usage: DATABASE_URL=postgres://... BACKUP_DIR=/var/backups/icarus scripts/backup.sh
#
# Writes icarus-<UTC time>.dump (pg_dump custom format), encrypted when a recipient is set,
# then deletes backups older than the retention period. Prints the path of the new file.
#
# Environment:
#   DATABASE_URL           required. Connection string for pg_dump.
#   BACKUP_DIR             default ./backups. Created with mode 700.
#   BACKUP_RETENTION_DAYS  default 30. Matching files older than this (by mtime) are deleted.
#   BACKUP_AGE_RECIPIENT   optional. An age public key (age1...). Output gets a .age suffix.
#   BACKUP_GPG_RECIPIENT   optional. A gpg recipient. Output gets a .gpg suffix. Set one of the two, not both.
set -euo pipefail

: "${DATABASE_URL:?set DATABASE_URL}"
BACKUP_DIR="${BACKUP_DIR:-./backups}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
AGE_RECIPIENT="${BACKUP_AGE_RECIPIENT:-}"
GPG_RECIPIENT="${BACKUP_GPG_RECIPIENT:-}"

if [[ -n "$AGE_RECIPIENT" && -n "$GPG_RECIPIENT" ]]; then
  echo "backup: set BACKUP_AGE_RECIPIENT or BACKUP_GPG_RECIPIENT, not both" >&2
  exit 2
fi
if [[ ! "$RETENTION_DAYS" =~ ^[0-9]+$ ]]; then
  echo "backup: BACKUP_RETENTION_DAYS must be a whole number of days" >&2
  exit 2
fi

umask 077
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
suffix=""
if [[ -n "$AGE_RECIPIENT" ]]; then
  suffix=".age"
elif [[ -n "$GPG_RECIPIENT" ]]; then
  suffix=".gpg"
fi
out="$BACKUP_DIR/icarus-$stamp.dump$suffix"
partial="$out.partial"
# A failed dump leaves no partial file behind.
trap 'rm -f -- "$partial"' EXIT

# --no-owner and --no-acl let the dump restore under any role name.
dump() {
  pg_dump --format=custom --no-owner --no-acl --dbname="$DATABASE_URL"
}

if [[ -n "$AGE_RECIPIENT" ]]; then
  dump | age --recipient "$AGE_RECIPIENT" --output "$partial"
elif [[ -n "$GPG_RECIPIENT" ]]; then
  dump | gpg --batch --yes --trust-model always --encrypt --recipient "$GPG_RECIPIENT" \
    --output "$partial"
else
  dump >"$partial"
fi

# Rename only after a complete dump, so a half-written file never looks like a backup.
mv "$partial" "$out"
echo "backup: wrote $out" >&2

find "$BACKUP_DIR" -maxdepth 1 -type f -name 'icarus-*.dump*' -mtime +"$RETENTION_DAYS" -delete
echo "backup: pruned files older than $RETENTION_DAYS days" >&2

echo "$out"
