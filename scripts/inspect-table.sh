#!/bin/bash
# inspect-table.sh
# Inspects schema, row counts, replication state, and sample rows across all nodes.
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
PG3_CONTAINER="${PG3_CONTAINER:-pg3}"
PG_SUPERUSER="${PG_SUPERUSER:-postgres}"
APP_DB="${APP_DB:-appdb}"
TABLE="${1:-events}"
LIMIT="${2:-10}"

NODES=("$PG1_CONTAINER" "$PG2_CONTAINER" "$PG3_CONTAINER")

# ── 1. Check containers ───────────────────────────────────────────────────────

for node in "${NODES[@]}"; do
    if ! docker ps --format '{{.Names}}' | grep -qw "$node"; then
        echo "ERROR: Container $node is not running." >&2
        exit 1
    fi
done

run_sql() {
    local node=$1
    shift
    docker exec "$node" psql -U "$PG_SUPERUSER" -d "$APP_DB" "$@"
}

echo "================================================================================"
echo " Table Inspection: $TABLE (database: $APP_DB)"
echo " Nodes: pg1 (5432) | pg2 (5433) | pg3 (5434)"
echo "================================================================================"

# ── 2. Table Schema (from first node) ─────────────────────────────────────────

echo ""
echo "--- Schema ($PG1_CONTAINER) ---"
run_sql "$PG1_CONTAINER" -c "\d $TABLE"

# ── 3. Replication State ──────────────────────────────────────────────────────

echo ""
echo "--- Logical Replication Status for '$TABLE' ---"
for node in "${NODES[@]}"; do
    echo "[$node Subscriptions]:"
    run_sql "$node" -c "
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
    " || echo "  (Table not tracked or not found in subscriptions on $node)"
done

# ── 4. Row Counts & Parity ────────────────────────────────────────────────────

echo ""
echo "--- Row Counts & Consistency ---"
declare -A counts
all_match=true
first_count=""

for node in "${NODES[@]}"; do
    c=$(run_sql "$node" -tAc "SELECT count(*) FROM $TABLE;")
    counts["$node"]=$c
    echo "  $node count : $c"
    if [ -z "$first_count" ]; then
        first_count=$c
    elif [ "$c" -ne "$first_count" ]; then
        all_match=false
    fi
done

if [ "$all_match" = true ]; then
    echo "  Counts Match   : YES (all $first_count)"
else
    echo "  Counts Match   : NO (mismatch detected!)"
fi

# Compare IDs across all nodes if 'id' column exists
has_id=$(run_sql "$PG1_CONTAINER" -tAc "
SELECT count(*) FROM information_schema.columns
WHERE table_name = '$TABLE' AND column_name = 'id';
")

if [ "$has_id" -ge 1 ]; then
    echo ""
    echo "--- ID Parity Check ---"
    diff12=$(diff -u <(run_sql "$PG1_CONTAINER" -tAc "SELECT id FROM $TABLE ORDER BY id;") \
                    <(run_sql "$PG2_CONTAINER" -tAc "SELECT id FROM $TABLE ORDER BY id;") || true)
    diff13=$(diff -u <(run_sql "$PG1_CONTAINER" -tAc "SELECT id FROM $TABLE ORDER BY id;") \
                    <(run_sql "$PG3_CONTAINER" -tAc "SELECT id FROM $TABLE ORDER BY id;") || true)

    if [ -z "$diff12" ] && [ -z "$diff13" ]; then
        echo "  All IDs match across all 3 nodes."
    else
        echo "  ID Discrepancies detected!"
        [ -n "$diff12" ] && echo "  pg1 vs pg2 diff:" && echo "$diff12"
        [ -n "$diff13" ] && echo "  pg1 vs pg3 diff:" && echo "$diff13"
    fi
fi

# ── 5. Sample Rows ────────────────────────────────────────────────────────────

for node in "${NODES[@]}"; do
    echo ""
    echo "--- Sample Rows (latest $LIMIT on $node) ---"
    run_sql "$node" -c "SELECT * FROM $TABLE ORDER BY ctid DESC LIMIT $LIMIT;"
done

echo ""
echo "Done."
