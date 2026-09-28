# PostgreSQL 18 — Active-Active Cluster (Docker Compose)

Full-mesh bidirectional logical replication across three PostgreSQL 18 nodes.  
All three nodes accept reads **and** writes; changes propagate across all nodes automatically.

```
         pg1 (localhost:5432)
              ▲         ▲
             ╱           ╲
            ▼             ▼
  pg2 (localhost:5433) <───> pg3 (localhost:5434)
```

> **Caveat:** PostgreSQL logical replication does not auto-resolve write conflicts  
> (e.g. two nodes updating the same row concurrently). Conflict handling must be  
> designed at the application layer (e.g. last-write-wins, origin-tagging, or  
> avoiding overlapping write sets per node).

## Directory layout

```
.
├── config/
│   ├── pg1/
│   │   ├── postgresql.conf
│   │   └── pg_hba.conf
│   ├── pg2/
│   │   ├── postgresql.conf
│   │   └── pg_hba.conf
│   └── pg3/
│       ├── postgresql.conf
│       └── pg_hba.conf
├── data/           # created at runtime, git-ignored
│   ├── pg1/
│   ├── pg2/
│   └── pg3/
├── scripts/
│   ├── init-pg1.sh          # runs once on pg1 first start
│   ├── init-pg2.sh          # runs once on pg2 first start
│   ├── init-pg3.sh          # runs once on pg3 first start
│   ├── setup-replication.sh # wire up full-mesh subscriptions
│   ├── test-cluster.sh      # end-to-end replication tests
│   ├── inspect-table.sh     # inspect schema, row parity & sample data across nodes
│   ├── start.sh             # wrapper to up containers and wire replication
│   └── stop.sh              # teardown containers and volumes
├── docker-compose.yml
└── .env                     # credentials (git-ignored)
```

## Quick start

### 1. Start the cluster

```bash
./scripts/start.sh
```

Or manually:

```bash
docker compose up -d
./scripts/setup-replication.sh
```

This creates full-mesh subscriptions:
- `pg1` subscribes to `pg2` and `pg3`
- `pg2` subscribes to `pg1` and `pg3`
- `pg3` subscribes to `pg1` and `pg2`

### 2. Run the tests

```bash
./scripts/test-cluster.sh
```

### 3. Inspect table data & parity

```bash
./scripts/inspect-table.sh events 10
```

### 4. Connect manually

```bash
# Node 1
psql -h localhost -p 5432 -U postgres -d appdb

# Node 2
psql -h localhost -p 5433 -U postgres -d appdb

# Node 3
psql -h localhost -p 5434 -U postgres -d appdb
```

## Tear down

```bash
docker compose down -v
rm -rf data/
```

## Environment variables

| Variable              | Default            | Description                    |
|-----------------------|--------------------|--------------------------------|
| `POSTGRES_USER`       | `postgres`         | Superuser name                 |
| `POSTGRES_PASSWORD`   | `postgres`         | Superuser password             |
| `REPLICATOR_PASSWORD` | `replicator_secret`| Password for `replicator` role |
| `APP_DB`              | `appdb`            | Application database name      |

Override in `.env` before starting.

## How replication works

1. Each node runs with `wal_level = logical`.
2. On first start, each init script creates a **publication** (`pub_pg1` / `pub_pg2`) covering all tables.
3. `setup-replication.sh` creates a **subscription** on each node pointing to the peer's publication.
4. PostgreSQL's logical replication worker streams WAL changes between nodes in real time.
