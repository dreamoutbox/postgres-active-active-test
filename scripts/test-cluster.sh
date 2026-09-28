#!/bin/bash
# test-cluster.sh
# Tests the active-active PostgreSQL setup:
#   1. Write to pg1, verify it appears on pg2
#   2. Write to pg2, verify it appears on pg1
#   3. Concurrent writes to both nodes
#   4. Row count consistency
#   5. Subscription health
#   6. Replication lag
# Runs all SQL via docker exec — no host psql required.
set -euo pipefail

PG1_CONTAINER="${PG1_CONTAINER:-pg1}"
PG2_CONTAINER="${PG2_CONTAINER:-pg2}"
PG_SUPERUSER="${PG_SUPERUSER:-postgres}"
APP_DB="${APP_DB:-appdb}"
WAIT_SECS="${WAIT_SECS:-5}"

# Wrappers: run psql inside each container via local Unix socket (no auth needed)
pg1() { docker exec "$PG1_CONTAINER" psql -U "$PG_SUPERUSER" -d "$APP_DB" "$@"; }
pg2() { docker exec "$PG2_CONTAINER" psql -U "$PG_SUPERUSER" -d "$APP_DB" "$@"; }

PASS=0
FAIL=0

pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
section() { echo; echo "=== $1 ==="; }

# ── helpers ───────────────────────────────────────────────────────────────────

wait_for_row() {
    local on_node=$1   # "pg1" or "pg2"
    local tag=$2
    local retries=$((WAIT_SECS * 2))

    while [ "$retries" -gt 0 ]; do
        count=$("$on_node" -tAc "SELECT count(*) FROM events WHERE payload = '$tag';")
        [ "$count" -ge 1 ] && return 0
        sleep 0.5
        retries=$((retries - 1))
    done
    return 1
}

# ── setup: clear table ────────────────────────────────────────────────────────

section "Setup: truncating events on both nodes"
pg1 -c "TRUNCATE TABLE events;"
sleep "$WAIT_SECS"
c1=$(pg1 -tAc "SELECT count(*) FROM events;")
c2=$(pg2 -tAc "SELECT count(*) FROM events;")
echo "  pg1=$c1  pg2=$c2"

# ── test 1: pg1 -> pg2 ────────────────────────────────────────────────────────

section "Test 1: Write to pg1, verify on pg2"
TAG1="test1_$(date +%s)"
pg1 -c "INSERT INTO events (node, payload) VALUES ('pg1', '$TAG1');"
echo "  Waiting up to ${WAIT_SECS}s..."
if wait_for_row "pg2" "$TAG1"; then
    pass "pg1 -> pg2: '$TAG1' replicated"
else
    fail "pg1 -> pg2: '$TAG1' NOT found on pg2 after ${WAIT_SECS}s"
fi

# ── test 2: pg2 -> pg1 ────────────────────────────────────────────────────────

section "Test 2: Write to pg2, verify on pg1"
TAG2="test2_$(date +%s)"
pg2 -c "INSERT INTO events (node, payload) VALUES ('pg2', '$TAG2');"
echo "  Waiting up to ${WAIT_SECS}s..."
if wait_for_row "pg1" "$TAG2"; then
    pass "pg2 -> pg1: '$TAG2' replicated"
else
    fail "pg2 -> pg1: '$TAG2' NOT found on pg1 after ${WAIT_SECS}s"
fi

# ── test 3: concurrent writes ─────────────────────────────────────────────────

section "Test 3: Concurrent writes to both nodes"
TAG3A="test3a_$(date +%s)"
TAG3B="test3b_$(date +%s)"
pg1 -c "INSERT INTO events (node, payload) VALUES ('pg1', '$TAG3A');" &
pg2 -c "INSERT INTO events (node, payload) VALUES ('pg2', '$TAG3B');" &
wait
echo "  Inserts done, waiting ${WAIT_SECS}s..."
sleep "$WAIT_SECS"

c_pg2_a=$(pg2 -tAc "SELECT count(*) FROM events WHERE payload = '$TAG3A';")
c_pg1_b=$(pg1 -tAc "SELECT count(*) FROM events WHERE payload = '$TAG3B';")

[ "$c_pg2_a" -ge 1 ] && pass "Concurrent pg1 write ('$TAG3A') on pg2" \
                      || fail "Concurrent pg1 write ('$TAG3A') NOT on pg2"
[ "$c_pg1_b" -ge 1 ] && pass "Concurrent pg2 write ('$TAG3B') on pg1" \
                      || fail "Concurrent pg2 write ('$TAG3B') NOT on pg1"

# ── test 4: row count consistency ─────────────────────────────────────────────

section "Test 4: Row count consistency"
sleep 1
rc1=$(pg1 -tAc "SELECT count(*) FROM events;")
rc2=$(pg2 -tAc "SELECT count(*) FROM events;")
echo "  pg1=$rc1  pg2=$rc2"
[ "$rc1" -eq "$rc2" ] && pass "Row counts match ($rc1)" \
                       || fail "Row count mismatch: pg1=$rc1 pg2=$rc2"

# ── test 5: subscription health ───────────────────────────────────────────────

section "Test 5: Subscription health"
sub1=$(pg1 -tAc "SELECT count(*) FROM pg_subscription WHERE subenabled = true;")
sub2=$(pg2 -tAc "SELECT count(*) FROM pg_subscription WHERE subenabled = true;")
[ "$sub1" -ge 1 ] && pass "pg1 has $sub1 active subscription(s)" \
                   || fail "pg1 has no active subscriptions"
[ "$sub2" -ge 1 ] && pass "pg2 has $sub2 active subscription(s)" \
                   || fail "pg2 has no active subscriptions"

# ── test 6: replication lag ───────────────────────────────────────────────────

section "Test 6: Replication senders"
echo "  pg1:"
pg1 -c "SELECT application_name, state, sent_lsn, write_lsn, replay_lsn FROM pg_stat_replication;" || true
echo "  pg2:"
pg2 -c "SELECT application_name, state, sent_lsn, write_lsn, replay_lsn FROM pg_stat_replication;" || true

# ── summary ───────────────────────────────────────────────────────────────────

section "Summary"
echo "  Passed: $PASS  Failed: $FAIL"
echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "All tests passed. Active-active cluster is working correctly."
    exit 0
else
    echo "Some tests FAILED. Check replication setup." >&2
    exit 1
fi
