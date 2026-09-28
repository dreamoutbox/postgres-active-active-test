#!/bin/bash
# Init script for pg3 — runs once on first container start.
set -euo pipefail

PG_USER="${POSTGRES_USER}"
APP_DB="${APP_DB:-appdb}"
REPLICATOR_PASSWORD="${REPLICATOR_PASSWORD}"

echo "[pg3-init] Creating app database and replication role..."

psql -v ON_ERROR_STOP=1 --username "$PG_USER" --dbname postgres <<SQL
CREATE DATABASE $APP_DB;
CREATE ROLE replicator WITH LOGIN REPLICATION PASSWORD '$REPLICATOR_PASSWORD';
GRANT CONNECT ON DATABASE $APP_DB TO replicator;
SQL

psql -v ON_ERROR_STOP=1 --username "$PG_USER" --dbname "$APP_DB" <<SQL
-- Use UUID (gen_random_uuid) for globally unique, collision-free primary keys across all nodes.
CREATE TABLE IF NOT EXISTS events (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    node        TEXT        NOT NULL,
    payload     TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Allow replicator role to access and look up objects inside the public schema
GRANT USAGE ON SCHEMA public TO replicator;

-- Allow replicator role to read existing rows during initial table sync (copy_data)
GRANT SELECT ON ALL TABLES IN SCHEMA public TO replicator;

-- Automatically grant SELECT to replicator on any newly created tables in the future
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO replicator;

-- Create publication that captures and streams WAL changes (INSERT/UPDATE/DELETE/TRUNCATE) for all tables
CREATE PUBLICATION pub_pg3 FOR ALL TABLES;
SQL

echo "[pg3-init] Done."
