#!/bin/bash
# setup-replication.sh
# Connects subscriptions between pg1 and pg2 after both nodes are running.
# Runs all SQL via docker exec — no host psql required.
# Safe to re-run: drops existing subscriptions before recreating.
set -euo pipefail

PG1_CONTAINER="${PG1_CONTAINER:-pg1}"
PG2_CONTAINER="${PG2_CONTAINER:-pg2}"
PG_SUPERUSER="${PG_SUPERUSER:-postgres}"
APP_DB="${APP_DB:-appdb}"
REPLICATOR_PASSWORD="${REPLICATOR_PASSWORD:-replicator_secret}"

# Run SQL on a container via docker exec (local socket — no auth issues)
pg1() { docker exec "$PG1_CONTAINER" psql -U "$PG_SUPERUSER" "$@"; }
pg2() { docker exec "$PG2_CONTAINER" psql -U "$PG_SUPERUSER" "$@"; }

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

# pg1 subscribes to pg2's publication (pg2 -> pg1)
echo "Creating subscription on pg1 (sub_from_pg2)..."
pg1 -d "$APP_DB" -c "DROP SUBSCRIPTION IF EXISTS sub_from_pg2;"
pg1 -d "$APP_DB" -c "CREATE SUBSCRIPTION sub_from_pg2 \
    CONNECTION 'host=$PG2_CONTAINER port=5432 dbname=$APP_DB user=replicator password=$REPLICATOR_PASSWORD' \
    PUBLICATION pub_pg2 \
    WITH (copy_data = true, create_slot = true, origin = none);"

# pg2 subscribes to pg1's publication (pg1 -> pg2)
echo "Creating subscription on pg2 (sub_from_pg1)..."
pg2 -d "$APP_DB" -c "DROP SUBSCRIPTION IF EXISTS sub_from_pg1;"
pg2 -d "$APP_DB" -c "CREATE SUBSCRIPTION sub_from_pg1 \
    CONNECTION 'host=$PG1_CONTAINER port=5432 dbname=$APP_DB user=replicator password=$REPLICATOR_PASSWORD' \
    PUBLICATION pub_pg1 \
    WITH (copy_data = true, create_slot = true, origin = none);"

echo ""
echo "Bidirectional replication configured:"
echo "  $PG1_CONTAINER <---> $PG2_CONTAINER"
echo ""

# Wait for subscriptions to reach streaming state (srsubstate = 'r')
# so callers don't run tests while initial table sync is still in progress.
wait_for_streaming() {
    local container=$1
    local retries=30
    echo "Waiting for $container subscriptions to reach streaming state..."
    until [ "$(docker exec "$container" psql -U "$PG_SUPERUSER" -d "$APP_DB" -tAc \
        "SELECT count(*) FROM pg_subscription_rel WHERE srsubstate != 'r';")" = "0" ] 2>/dev/null; do
        retries=$((retries - 1))
        [ "$retries" -le 0 ] && echo "WARNING: subscriptions on $container did not reach streaming state." && break
        printf "."
        sleep 2
    done
    echo " streaming."
}

wait_for_streaming "$PG1_CONTAINER"
wait_for_streaming "$PG2_CONTAINER"

echo "Subscription status:"
pg1 -d "$APP_DB" -c "SELECT subname, subenabled, subslotname FROM pg_subscription;"
pg2 -d "$APP_DB" -c "SELECT subname, subenabled, subslotname FROM pg_subscription;"
