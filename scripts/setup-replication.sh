#!/bin/bash
# setup-replication.sh
# Connects full-mesh subscriptions across pg1, pg2, and pg3.
# Runs all SQL via docker exec — no host psql required.
# Safe to re-run: drops existing subscriptions before recreating.
set -euo pipefail

PG1_CONTAINER="${PG1_CONTAINER:-pg1}"
PG2_CONTAINER="${PG2_CONTAINER:-pg2}"
PG3_CONTAINER="${PG3_CONTAINER:-pg3}"
PG_SUPERUSER="${PG_SUPERUSER:-postgres}"
APP_DB="${APP_DB:-appdb}"
REPLICATOR_PASSWORD="${REPLICATOR_PASSWORD:-replicator_secret}"

wait_for_postgres() {
    local container=$1
    local retries=30

    echo "Waiting for $container..."
    until docker exec "$container" pg_isready -U "$PG_SUPERUSER" -d postgres -q 2>/dev/null; do
        retries=$((retries - 1))
        if [ "$retries" -le 0 ]; then
            echo "ERROR: $container did not become ready in time." >&2
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

# Helper to create subscription from source_node on target_node
create_sub() {
    local target_node=$1
    local source_node=$2
    local pub_name="pub_${source_node}"
    local sub_name="sub_${target_node}_from_${source_node}"
    local legacy_sub_name="sub_from_${source_node}"

    echo "Configuring subscription on $target_node: $sub_name -> $source_node ($pub_name)..."
    docker exec "$target_node" psql -U "$PG_SUPERUSER" -d "$APP_DB" \
        -c "DROP SUBSCRIPTION IF EXISTS $legacy_sub_name;" 2>/dev/null || true
    docker exec "$target_node" psql -U "$PG_SUPERUSER" -d "$APP_DB" \
        -c "DROP SUBSCRIPTION IF EXISTS $sub_name;"
    docker exec "$target_node" psql -U "$PG_SUPERUSER" -d "$APP_DB" \
        -c "CREATE SUBSCRIPTION $sub_name CONNECTION 'host=$source_node port=5432 dbname=$APP_DB user=replicator password=$REPLICATOR_PASSWORD' PUBLICATION $pub_name WITH (copy_data = true, create_slot = true, origin = none);"
}

# ── 1. Create full-mesh subscriptions ──────────────────────────────────────────

# pg1 subscribes to pg2 and pg3
create_sub "$PG1_CONTAINER" "$PG2_CONTAINER"
create_sub "$PG1_CONTAINER" "$PG3_CONTAINER"

# pg2 subscribes to pg1 and pg3
create_sub "$PG2_CONTAINER" "$PG1_CONTAINER"
create_sub "$PG2_CONTAINER" "$PG3_CONTAINER"

# pg3 subscribes to pg1 and pg2
create_sub "$PG3_CONTAINER" "$PG1_CONTAINER"
create_sub "$PG3_CONTAINER" "$PG2_CONTAINER"

echo ""
echo "Full-mesh replication configured:"
echo "  $PG1_CONTAINER <---> $PG2_CONTAINER <---> $PG3_CONTAINER"
echo ""

# ── 2. Wait for initial table sync to reach streaming state ───────────────────

wait_for_streaming() {
    local container=$1
    local retries=30
    echo "Waiting for $container subscriptions to reach streaming state..."
    until [ "$(docker exec "$container" psql -U "$PG_SUPERUSER" -d "$APP_DB" -tAc \
        "SELECT count(*) FROM pg_subscription_rel WHERE srsubstate != 'r';")" = "0" ] 2>/dev/null; do
        retries=$((retries - 1))
        if [ "$retries" -le 0 ]; then
            echo "WARNING: subscriptions on $container did not reach streaming state in time."
            break
        fi
        printf "."
        sleep 2
    done
    echo " streaming."
}

wait_for_streaming "$PG1_CONTAINER"
wait_for_streaming "$PG2_CONTAINER"
wait_for_streaming "$PG3_CONTAINER"

echo ""
echo "Subscription status:"
for c in "$PG1_CONTAINER" "$PG2_CONTAINER" "$PG3_CONTAINER"; do
    echo "[$c]:"
    docker exec "$c" psql -U "$PG_SUPERUSER" -d "$APP_DB" -c \
        "SELECT subname, subenabled, subslotname FROM pg_subscription;"
done
