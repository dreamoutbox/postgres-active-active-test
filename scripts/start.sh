#!/bin/bash
# start.sh
# Brings up the cluster and configures replication if not already done.
# Safe to re-run: skips replication setup if subscriptions already exist.
# Uses docker exec for all SQL — no host psql required.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load .env for variable access
set -a
# shellcheck source=../.env
source "$ROOT_DIR/.env"
set +a

PG1_CONTAINER="${PG1_CONTAINER:-pg1}"
PG2_CONTAINER="${PG2_CONTAINER:-pg2}"
PG3_CONTAINER="${PG3_CONTAINER:-pg3}"
PG_SUPERUSER="${PG_SUPERUSER:-postgres}"

# ── 1. Start containers ───────────────────────────────────────────────────────

echo "[start] Starting cluster..."
docker compose -f "$ROOT_DIR/docker-compose.yml" up -d

# ── 2. Wait for all nodes ─────────────────────────────────────────────────────

wait_for_postgres() {
    local container=$1
    local retries=30

    echo "[start] Waiting for $container..."
    until docker exec "$container" pg_isready -U "$PG_SUPERUSER" -d postgres -q 2>/dev/null; do
        retries=$((retries - 1))
        if [ "$retries" -le 0 ]; then
            echo "[start] ERROR: $container did not become ready." >&2
            exit 1
        fi
        printf "."
        sleep 2
    done
    echo " ready."
}

wait_for_postgres "$PG1_CONTAINER"
wait_for_postgres "$PG2_CONTAINER"
wait_for_postgres "$PG3_CONTAINER"

# ── 3. Check if replication already configured ────────────────────────────────

sub_count=$(docker exec "$PG1_CONTAINER" psql -U "$PG_SUPERUSER" -d "$APP_DB" \
    -tAc "SELECT count(*) FROM pg_subscription;" 2>/dev/null || echo 0)

if [ "$sub_count" -ge 2 ]; then
    echo "[start] Replication already configured ($sub_count subscription(s) on $PG1_CONTAINER). Skipping setup."
else
    echo "[start] Subscriptions missing or incomplete ($sub_count found) — running replication setup..."
    PG1_CONTAINER="$PG1_CONTAINER" \
    PG2_CONTAINER="$PG2_CONTAINER" \
    PG3_CONTAINER="$PG3_CONTAINER" \
    PG_SUPERUSER="$PG_SUPERUSER" \
    APP_DB="$APP_DB" \
    REPLICATOR_PASSWORD="$REPLICATOR_PASSWORD" \
        "$SCRIPT_DIR/setup-replication.sh"
    echo "[start] Replication setup complete."
fi

# ── 4. Done ───────────────────────────────────────────────────────────────────

echo ""
echo "Cluster is up:"
echo "  pg1  ->  localhost:5432  ($PG1_CONTAINER)"
echo "  pg2  ->  localhost:5433  ($PG2_CONTAINER)"
echo "  pg3  ->  localhost:5434  ($PG3_CONTAINER)"
echo ""
echo "Run tests:  ./scripts/test-cluster.sh"
