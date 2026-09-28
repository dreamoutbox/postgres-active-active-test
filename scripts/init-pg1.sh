#!/bin/bash
# Init script for pg1 — runs once on first container start.
set -euo pipefail

PG_USER="${POSTGRES_USER}"
APP_DB="${APP_DB:-appdb}"
REPLICATOR_PASSWORD="${REPLICATOR_PASSWORD}"

echo "[pg1-init] Creating app database and replication role..."

psql -v ON_ERROR_STOP=1 --username "$PG_USER" --dbname postgres <<SQL
CREATE DATABASE $APP_DB;
CREATE ROLE replicator WITH LOGIN REPLICATION PASSWORD '$REPLICATOR_PASSWORD';
GRANT CONNECT ON DATABASE $APP_DB TO replicator;
SQL

psql -v ON_ERROR_STOP=1 --username "$PG_USER" --dbname "$APP_DB" <<SQL
-- Sequence: starts at 1, increments by 2 (pg1 owns odd IDs: 1, 3, 5 ...)
-- This avoids PK conflicts when pg2 generates even IDs: 2, 4, 6 ...
CREATE SEQUENCE events_id_seq START 1 INCREMENT 2;

CREATE TABLE IF NOT EXISTS events (
    id          BIGINT      PRIMARY KEY DEFAULT nextval('events_id_seq'),
    node        TEXT        NOT NULL,
    payload     TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

GRANT USAGE ON SCHEMA public TO replicator;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO replicator;
GRANT USAGE ON SEQUENCE events_id_seq TO replicator;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO replicator;

CREATE PUBLICATION pub_pg1 FOR ALL TABLES;
SQL

echo "[pg1-init] Done."
