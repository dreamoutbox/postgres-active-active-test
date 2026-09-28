#!/bin/bash
# test-cluster.sh
# Tests the 3-node active-active PostgreSQL setup:
#   1. Write to pg1 -> verify on pg2 and pg3
#   2. Write to pg2 -> verify on pg1 and pg3
#   3. Write to pg3 -> verify on pg1 and pg2
#   4. Concurrent writes to all 3 nodes
#   5. Row count consistency across all 3 nodes
#   6. Subscription health across all 3 nodes
#   7. Replication sender states
# Runs all SQL via docker exec — no host psql required.
set -euo pipefail

PG1_CONTAINER="${PG1_CONTAINER:-pg1}"
PG2_CONTAINER="${PG2_CONTAINER:-pg2}"
PG3_CONTAINER="${PG3_CONTAINER:-pg3}"
PG_SUPERUSER="${PG_SUPERUSER:-postgres}"
APP_DB="${APP_DB:-appdb}"
WAIT_SECS="${WAIT_SECS:-5}"

# Wrappers: run psql inside each container via local Unix socket
pg1() { docker exec "$PG1_CONTAINER" psql -U "$PG_SUPERUSER" -d "$APP_DB" "$@"; }
pg2() { docker exec "$PG2_CONTAINER" psql -U "$PG_SUPERUSER" -d "$APP_DB" "$@"; }
pg3() { docker exec "$PG3_CONTAINER" psql -U "$PG_SUPERUSER" -d "$APP_DB" "$@"; }

PASS=0
FAIL=0

pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
section() { echo; echo "=== $1 ==="; }

# ── helpers ───────────────────────────────────────────────────────────────────

wait_for_row() {
    local node_fn=$1   # "pg1", "pg2", or "pg3"
    local tag=$2
    local retries=$((WAIT_SECS * 2))

    while [ "$retries" -gt 0 ]; do
        count=$("$node_fn" -tAc "SELECT count(*) FROM events WHERE payload = '$tag';")
        [ "$count" -ge 1 ] && return 0
        sleep 0.5
        retries=$((retries - 1))
    done
    return 1
}

# ── setup: clear table ────────────────────────────────────────────────────────

section "Setup: truncating events on cluster"
pg1 -c "TRUNCATE TABLE events;"
sleep "$WAIT_SECS"
c1=$(pg1 -tAc "SELECT count(*) FROM events;")
c2=$(pg2 -tAc "SELECT count(*) FROM events;")
c3=$(pg3 -tAc "SELECT count(*) FROM events;")
echo "  pg1=$c1  pg2=$c2  pg3=$c3"

# ── test 1: pg1 -> pg2 & pg3 ──────────────────────────────────────────────────

section "Test 1: Write to pg1, verify on pg2 and pg3"
TAG1="test1_$(date +%s)"
pg1 -c "INSERT INTO events (node, payload) VALUES ('pg1', '$TAG1');"
echo "  Waiting up to ${WAIT_SECS}s..."

if wait_for_row "pg2" "$TAG1"; then
    pass "pg1 -> pg2: '$TAG1' replicated"
else
    fail "pg1 -> pg2: '$TAG1' NOT found on pg2"
fi

if wait_for_row "pg3" "$TAG1"; then
    pass "pg1 -> pg3: '$TAG1' replicated"
else
    fail "pg1 -> pg3: '$TAG1' NOT found on pg3"
fi

# ── test 2: pg2 -> pg1 & pg3 ──────────────────────────────────────────────────

section "Test 2: Write to pg2, verify on pg1 and pg3"
TAG2="test2_$(date +%s)"
pg2 -c "INSERT INTO events (node, payload) VALUES ('pg2', '$TAG2');"
echo "  Waiting up to ${WAIT_SECS}s..."

if wait_for_row "pg1" "$TAG2"; then
    pass "pg2 -> pg1: '$TAG2' replicated"
else
    fail "pg2 -> pg1: '$TAG2' NOT found on pg1"
fi

if wait_for_row "pg3" "$TAG2"; then
    pass "pg2 -> pg3: '$TAG2' replicated"
else
    fail "pg2 -> pg3: '$TAG2' NOT found on pg3"
fi

# ── test 3: pg3 -> pg1 & pg2 ──────────────────────────────────────────────────

section "Test 3: Write to pg3, verify on pg1 and pg2"
TAG3="test3_$(date +%s)"
pg3 -c "INSERT INTO events (node, payload) VALUES ('pg3', '$TAG3');"
echo "  Waiting up to ${WAIT_SECS}s..."

if wait_for_row "pg1" "$TAG3"; then
    pass "pg3 -> pg1: '$TAG3' replicated"
else
    fail "pg3 -> pg1: '$TAG3' NOT found on pg1"
fi

if wait_for_row "pg2" "$TAG3"; then
    pass "pg3 -> pg2: '$TAG3' replicated"
else
    fail "pg3 -> pg2: '$TAG3' NOT found on pg2"
fi

# ── test 4: concurrent writes across all 3 nodes ──────────────────────────────

section "Test 4: Concurrent writes to all 3 nodes"
TAG4A="test4a_$(date +%s)"
TAG4B="test4b_$(date +%s)"
TAG4C="test4c_$(date +%s)"

pg1 -c "INSERT INTO events (node, payload) VALUES ('pg1', '$TAG4A');" &
pg2 -c "INSERT INTO events (node, payload) VALUES ('pg2', '$TAG4B');" &
pg3 -c "INSERT INTO events (node, payload) VALUES ('pg3', '$TAG4C');" &
wait
echo "  Inserts done, waiting ${WAIT_SECS}s..."
sleep "$WAIT_SECS"

# Verify all tags exist on all nodes
for node in "pg1" "pg2" "pg3"; do
    c_a=$("$node" -tAc "SELECT count(*) FROM events WHERE payload = '$TAG4A';")
    c_b=$("$node" -tAc "SELECT count(*) FROM events WHERE payload = '$TAG4B';")
    c_c=$("$node" -tAc "SELECT count(*) FROM events WHERE payload = '$TAG4C';")

    [ "$c_a" -ge 1 ] && pass "$node has concurrent write A ('$TAG4A')" \
                     || fail "$node missing concurrent write A ('$TAG4A')"
    [ "$c_b" -ge 1 ] && pass "$node has concurrent write B ('$TAG4B')" \
                     || fail "$node missing concurrent write B ('$TAG4B')"
    [ "$c_c" -ge 1 ] && pass "$node has concurrent write C ('$TAG4C')" \
                     || fail "$node missing concurrent write C ('$TAG4C')"
done

# ── test 5: row count consistency ─────────────────────────────────────────────

section "Test 5: Row count consistency across all nodes"
sleep 1
rc1=$(pg1 -tAc "SELECT count(*) FROM events;")
rc2=$(pg2 -tAc "SELECT count(*) FROM events;")
rc3=$(pg3 -tAc "SELECT count(*) FROM events;")
echo "  pg1=$rc1  pg2=$rc2  pg3=$rc3"

if [ "$rc1" -eq "$rc2" ] && [ "$rc2" -eq "$rc3" ]; then
    pass "All 3 nodes have matching row counts ($rc1)"
else
    fail "Row count mismatch: pg1=$rc1 pg2=$rc2 pg3=$rc3"
fi

# ── test 6: subscription health ───────────────────────────────────────────────

section "Test 6: Subscription health"
for node in "pg1" "pg2" "pg3"; do
    sub_count=$("$node" -tAc "SELECT count(*) FROM pg_subscription WHERE subenabled = true;")
    [ "$sub_count" -ge 2 ] && pass "$node has $sub_count active subscription(s)" \
                           || fail "$node has fewer than 2 active subscriptions ($sub_count)"
done

# ── test 7: replication lag / senders ─────────────────────────────────────────

section "Test 7: Replication senders"
for node in "pg1" "pg2" "pg3"; do
    echo "  $node senders:"
    "$node" -c "SELECT application_name, state, sent_lsn, write_lsn, replay_lsn FROM pg_stat_replication;" || true
done

# ── summary ───────────────────────────────────────────────────────────────────

section "Summary"
echo "  Passed: $PASS  Failed: $FAIL"
echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "All tests passed. 3-node active-active cluster is working correctly."
    exit 0
else
    echo "Some tests FAILED. Check replication setup." >&2
    exit 1
fi
