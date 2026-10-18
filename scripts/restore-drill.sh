#!/usr/bin/env bash
# Restore drill (PLAN.md §18, §19 Phase 8, docs/backup.md): back up a seeded database, restore the
# dump into a fresh database, and compare exact row counts for every table.
#
# Usage: SOURCE_DATABASE_URL=postgres://... ADMIN_DATABASE_URL=postgres://.../postgres scripts/restore-drill.sh
#
# Environment:
#   SOURCE_DATABASE_URL  required. The seeded database to back up. It is only read.
#   ADMIN_DATABASE_URL   required. A connection that may CREATE and DROP databases (e.g. the
#                        maintenance database "postgres" on the same server).
#   DRILL_KEEP           set to 1 to keep the scratch database and dump for inspection.
#
# Exit status is non-zero when the restore fails or any table's row count differs.
set -euo pipefail

: "${SOURCE_DATABASE_URL:?set SOURCE_DATABASE_URL to the seeded database}"
: "${ADMIN_DATABASE_URL:?set ADMIN_DATABASE_URL (a maintenance database on the same server)}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Same URL with a different database name. Keeps any ?query part.
with_database() {
  local url="$1" name="$2" base query=""
  base="${url%%\?*}"
  if [[ "$url" == *\?* ]]; then
    query="?${url#*\?}"
  fi
  echo "${base%/*}/$name$query"
}

work="$(mktemp -d)"
drill_db="icarus_drill_$(date -u +%Y%m%d%H%M%S)_$$"
target_url="$(with_database "$ADMIN_DATABASE_URL" "$drill_db")"
admin_psql=(psql --no-psqlrc --quiet --set=ON_ERROR_STOP=1 --dbname="$ADMIN_DATABASE_URL")

cleanup() {
  if [[ "${DRILL_KEEP:-0}" == "1" ]]; then
    echo "drill: kept $work and database $drill_db" >&2
    return
  fi
  "${admin_psql[@]}" --command="DROP DATABASE IF EXISTS \"$drill_db\" WITH (FORCE)" >/dev/null 2>&1 || true
  rm -rf -- "$work"
}
trap cleanup EXIT

echo "drill: backing up the source" >&2
dump="$(BACKUP_DIR="$work" DATABASE_URL="$SOURCE_DATABASE_URL" "$script_dir/backup.sh")"

echo "drill: creating $drill_db and restoring" >&2
"${admin_psql[@]}" --command="CREATE DATABASE \"$drill_db\""
TARGET_DATABASE_URL="$target_url" "$script_dir/restore.sh" "$dump"

list_tables() {
  psql --no-psqlrc --tuples-only --no-align --dbname="$1" --command="
    SELECT relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p') ORDER BY relname"
}

count_rows() {
  psql --no-psqlrc --tuples-only --no-align --dbname="$1" --command="SELECT count(*) FROM public.\"$2\""
}

echo "drill: comparing row counts" >&2
failures=0
printf '%-24s %12s %12s  %s\n' table source restored result
while IFS= read -r table; do
  [[ -z "$table" ]] && continue
  source_rows="$(count_rows "$SOURCE_DATABASE_URL" "$table")"
  restored_rows="$(count_rows "$target_url" "$table")"
  if [[ "$source_rows" == "$restored_rows" ]]; then
    result="ok"
  else
    result="MISMATCH"
    failures=$((failures + 1))
  fi
  printf '%-24s %12s %12s  %s\n' "$table" "$source_rows" "$restored_rows" "$result"
done < <(list_tables "$SOURCE_DATABASE_URL")

if [[ "$failures" -ne 0 ]]; then
  echo "drill: FAILED, $failures table(s) differ" >&2
  exit 1
fi
echo "drill: PASSED, every table matches" >&2
