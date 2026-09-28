#!/bin/bash
# inspect-table.sh
# Inspects schema, row counts, replication state, and sample rows across both nodes.
# Usage: ./scripts/inspect-table.sh [table_name] [limit]
#   table_name: defaults to "events"
#   limit:      defaults to 10
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -f "$ROOT_DIR/.env" ]; then
    set -a
    # shellcheck source=../.env
    source "$ROOT_DIR/.env"
    set +a
fi

PG1_CONTAINER="${PG1_CONTAINER:-pg1}"
PG2_CONTAINER="${PG2_CONTAINER:-pg2}"
PG_SUPERUSER="${PG_SUPERUSER:-postgres}"
APP_DB="${APP_DB:-appdb}"
TABLE="${1:-events}"
LIMIT="${2:-10}"

# Wrappers
pg1_sql() { docker exec "$PG1_CONTAINER" psql -U "$PG_SUPERUSER" -d "$APP_DB" "$@"; }
pg2_sql() { docker exec "$PG2_CONTAINER" psql -U "$PG_SUPERUSER" -d "$APP_DB" "$@"; }

# ── 1. Check containers ───────────────────────────────────────────────────────

if ! docker ps --format '{{.Names}}' | grep -qw "$PG1_CONTAINER"; then
    echo "ERROR: Container $PG1_CONTAINER is not running." >&2
    exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -qw "$PG2_CONTAINER"; then
    echo "ERROR: Container $PG2_CONTAINER is not running." >&2
    exit 1
fi

echo "================================================================================"
echo " Table Inspection: $TABLE (database: $APP_DB)"
echo " Nodes: $PG1_CONTAINER (localhost:5432) | $PG2_CONTAINER (localhost:5433)"
echo "================================================================================"

# ── 2. Table Schema (pg1) ─────────────────────────────────────────────────────

echo ""
echo "--- Schema ($PG1_CONTAINER) ---"
pg1_sql -c "\d $TABLE"

# ── 3. Replication State ──────────────────────────────────────────────────────

echo ""
echo "--- Logical Replication Status for '$TABLE' ---"
echo "[$PG1_CONTAINER Subscriptions]:"
pg1_sql -c "
SELECT subname, srsubstate,
       CASE srsubstate
           WHEN 'i' THEN 'initializing'
           WHEN 'd' THEN 'data copy'
           WHEN 's' THEN 'synchronized'
           WHEN 'r' THEN 'ready (streaming)'
           ELSE srsubstate::text
       END AS status
FROM pg_subscription_rel r
JOIN pg_subscription s ON s.oid = r.srsubid
WHERE srrelid = '$TABLE'::regclass;
" || echo "  (Table not tracked or not found in subscriptions on $PG1_CONTAINER)"

echo "[$PG2_CONTAINER Subscriptions]:"
pg2_sql -c "
SELECT subname, srsubstate,
       CASE srsubstate
           WHEN 'i' THEN 'initializing'
           WHEN 'd' THEN 'data copy'
           WHEN 's' THEN 'synchronized'
           WHEN 'r' THEN 'ready (streaming)'
           ELSE srsubstate::text
       END AS status
FROM pg_subscription_rel r
JOIN pg_subscription s ON s.oid = r.srsubid
WHERE srrelid = '$TABLE'::regclass;
" || echo "  (Table not tracked or not found in subscriptions on $PG2_CONTAINER)"

# ── 4. Row Counts & Parity ────────────────────────────────────────────────────

echo ""
echo "--- Row Counts & Consistency ---"
count1=$(pg1_sql -tAc "SELECT count(*) FROM $TABLE;")
count2=$(pg2_sql -tAc "SELECT count(*) FROM $TABLE;")

echo "  $PG1_CONTAINER count : $count1"
echo "  $PG2_CONTAINER count : $count2"

if [ "$count1" -eq "$count2" ]; then
    echo "  Counts Match   : YES"
else
    echo "  Counts Match   : NO (mismatch detected!)"
fi

# Compare IDs if 'id' column exists
has_id=$(pg1_sql -tAc "
SELECT count(*) FROM information_schema.columns
WHERE table_name = '$TABLE' AND column_name = 'id';
")

if [ "$has_id" -ge 1 ]; then
    echo ""
    echo "--- ID Parity Check ---"
    diff_output=$(diff -u \
        <(pg1_sql -tAc "SELECT id FROM $TABLE ORDER BY id;") \
        <(pg2_sql -tAc "SELECT id FROM $TABLE ORDER BY id;") || true)

    if [ -z "$diff_output" ]; then
        echo "  All IDs match between $PG1_CONTAINER and $PG2_CONTAINER."
    else
        echo "  ID Discrepancies detected (-$PG1_CONTAINER, +$PG2_CONTAINER):"
        echo "$diff_output"
    fi
fi

# ── 5. Sample Rows ────────────────────────────────────────────────────────────

echo ""
echo "--- Sample Rows (latest $LIMIT on $PG1_CONTAINER) ---"
pg1_sql -c "SELECT * FROM $TABLE ORDER BY ctid DESC LIMIT $LIMIT;"

echo ""
echo "--- Sample Rows (latest $LIMIT on $PG2_CONTAINER) ---"
pg2_sql -c "SELECT * FROM $TABLE ORDER BY ctid DESC LIMIT $LIMIT;"

echo ""
echo "Done."
