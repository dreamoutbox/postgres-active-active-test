# Postmortem: PostgreSQL 18 Active-Active Replication Setup Failures

**Date:** 2026-09-28
**Severity:** Medium
**Status:** Resolved

## Summary
Setting up an active-active two-node PostgreSQL 18 cluster with Docker Compose encountered multiple breaking configuration changes, volume mount directory structure incompatibilities, replication loops, and client connectivity failures. All issues were diagnosed and resolved, culminating in an automated setup wrapper and passing test suite.

## Impact
None. Isolated to local development environment setup.

## Root Cause
Multiple distinct underlying causes:
1. **PG 18 Data Directory Structure**: The official PostgreSQL 18 image nests cluster data under `/var/lib/postgresql/18/docker/` instead of directly at `/var/lib/postgresql/data`. Mounting host paths directly into `/var/lib/postgresql/data` interfered with initialization and directory permissions.
2. **Deprecated/Removed GUC Parameters**: `max_wal_receivers` was removed in PostgreSQL 16+, causing fatal errors on startup when included in `postgresql.conf`.
3. **Init Script Bypass**: Re-running containers against existing non-empty host directories bypassed `/docker-entrypoint-initdb.d/` execution.
4. **Heredoc Ingestion Failures via `docker exec`**: Piping heredoc SQL blocks into non-interactive `docker exec` sessions resulted in silently dropped statements (including `CREATE SUBSCRIPTION`).
5. **Host Authentication & Version Drift**: Host `psql` (v17) faced password/port mapping conflicts when connecting directly across Docker Desktop/WSL network boundaries to port 5433.
6. **Primary Key Collisions**: Default identity sequences starting at `1` with step `1` generated colliding primary keys on both nodes during concurrent writes (`conflict=insert_exists`).
7. **Replication Loops**: Logical replication by default forwards replicated changes back to the origin, causing TRUNCATE and INSERT feedback loops.
8. **Asynchronous Initial Table Sync**: Executing validation queries immediately after creating subscriptions raced with initial relation synchronization (`srsubstate != 'r'`).

## Detection
- Fatal container crash logs (`unrecognized configuration parameter "max_wal_receivers"`).
- Docker health check failures and `docker compose logs` showing init script bypass.
- Test script verification errors (`relation does not exist`, missing rows, primary key unique constraint violations).
- Replication worker crash logs reporting circular replication loops.

## Resolution
1. **Volume Mount**: Mounted volumes at `/var/lib/postgresql` rather than `/var/lib/postgresql/data`.
2. **Config Cleanup**: Removed `max_wal_receivers` from `config/pg1/postgresql.conf` and `config/pg2/postgresql.conf`.
3. **Clean Initialization**: Reset data directories and added cleanup procedures before initial runs.
4. **Command Flag Execution**: Switched all script SQL execution from heredocs to explicit `docker exec -i ... psql -c "<SQL>"` commands using internal container Unix sockets.
5. **Node-Specific Key Sequences**: Configured disjoint sequences per node: node 1 uses odd IDs (`START 1 INCREMENT 2`), node 2 uses even IDs (`START 2 INCREMENT 2`).
6. **Loop Prevention**: Added `WITH (origin = none)` to all `CREATE SUBSCRIPTION` commands to prevent circular replication.
7. **Sync Barrier**: Added polling loops in `setup-replication.sh` checking `pg_subscription_rel` until all table sync states reach `'r'` (ready) and `pg_stat_subscription` indicates active streaming.

## Lessons Learned / Action Items
- [ ] Verify configuration parameter support against target major PostgreSQL version before porting configuration files.
- [ ] Standardize on container-internal command execution (`docker exec`) for setup scripts to decouple automation from host-installed database clients.
- [ ] Configure `WITH (origin = none)` for all bidirectional logical replication configurations in PostgreSQL 16+.
- [ ] Block test execution and client queries until `pg_subscription_rel.srsubstate = 'r'` to prevent initial sync race conditions.
