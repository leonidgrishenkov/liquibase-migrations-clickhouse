# Liquibase on ClickHouse — test bed

A real ClickHouse **2-shard × 2-replica** cluster (26.3.17.110) with a Liquibase CLI
pointed at it. The question being tested: how well does Liquibase actually work against
ClickHouse — `ON CLUSTER` DDL, `ReplicatedMergeTree`, `Distributed` tables, rollbacks, and
reverse-engineering a database it did not create?

Nothing is installed on the host — Liquibase runs from a container.

## Quick start

```bash
docker pull public.ecr.aws/a8c0b5z6/liquibase-clickhouse:4.33.0-1
task up                   # 4 nodes + keeper, bootstrapped with schema and data
task migrations:lint      # check migrations against the repo conventions
task migrations:update    # apply them
task tables               # look at the result
```

Authoring a change:

```bash
task migrations:new NAME=create_orders CLUSTER=analytics_cluster DB=marts
```

Liquibase recipes live in `migrations/taskfile.yaml` and are namespaced `migrations:*`;
environment recipes (`up`, `down`, `nuke`, `tables`, `ddl`, `ch`, `logs`) stay at the root.
`task` on its own lists everything; `task migrations:liquibase -- <args>` runs any other
Liquibase command.

Requires [go-task](https://taskfile.dev).

## The cluster

```
analytics_cluster
  shard 01 -> ch-s1r1, ch-s1r2
  shard 02 -> ch-s2r1, ch-s2r2
  coordination -> keeper (single ClickHouse Keeper node)
```

Only `ch-s1r1` publishes ports (8123 / 9000); it is the entry point for
`clickhouse-client` and for Liquibase. Config is split in two:

- `clickhouse/config.d/00-cluster.xml` — shared by all four nodes: Keeper address,
  `remote_servers`, distributed DDL path, memory cap.
- `clickhouse/macros/<node>.xml` — per-node identity, mounted as `01-macros.xml`.

`internal_replication=true`, so an INSERT into a `Distributed` table is written to **one**
replica per shard and ClickHouse replicates it from there.

Two macro pairs are defined, because there are two ways to replicate a table:

| Macro pair | ZooKeeper path | Meaning |
|---|---|---|
| `{shard}` / `{replica}` | one path **per shard** | sharded — each shard holds a different slice |
| `{shard_broadcast}` / `{replica_broadcast}` | **one path cluster-wide** | broadcast — every shard holds the same copy |

Because broadcast puts every node on a single path, `{replica_broadcast}` must be unique
across the whole cluster, whereas `{replica}` only has to be unique within its shard.

> **Config files are mounted individually, never as a directory.** The ClickHouse image
> ships its own `config.d/docker_related_config.xml`, which sets `listen_host` to the
> wildcard address. Mounting the whole directory shadows it and the server silently binds
> to loopback only, unreachable from the other containers.

## What is already in the databases

Four databases, created by `clickhouse/initdb/00-databases.sql`:

| Database | Purpose |
|---|---|
| `liquibase` | Liquibase's own tracking tables, kept away from the data |
| `stage` | raw landing |
| `marts` | modelled |
| `bi` | presentation |

Each data database has two tables, following the standard ClickHouse pattern of a physical
per-shard table plus a logical one to read and write:

```
<name>_local   ReplicatedMergeTree('/clickhouse/tables/{shard}/{database}/{table}', '{replica}')
<name>         Distributed(analytics_cluster, <db>, <name>_local, cityHash64(<key>))
```

| Table | Rows | shard 01 / 02 |
|---|---|---|
| `stage.users` | 150 | 67 / 83 |
| `stage.events` | 200 | 89 / 111 |
| `marts.orders` | 180 | 82 / 98 |
| `marts.order_items` | 200 | 98 / 102 |
| `bi.daily_active_users` | 150 | 70 / 80 |
| `bi.revenue_daily` | 150 | 70 / 80 |

This is the fixture for "how does a migration tool cope with a database it did not
create?" — none of it comes from a migration.

### How the bootstrap works

`clickhouse/initdb/*.sql` is **not** mounted into the image's
`docker-entrypoint-initdb.d`. That hook runs per container, so all four nodes would race
to execute the same `ON CLUSTER` DDL and the seed INSERTs would run four times. Instead a
one-shot `bootstrap` service applies the files with `clickhouse-client` once every node is
healthy.

Each seed INSERT is guarded by a scalar subquery on its own target
(`WHERE (SELECT count() FROM t) = 0`), which makes the whole file idempotent — it re-runs
on every `up` and inserts nothing the second time.

> `docker compose up --wait` returns once containers are healthy or *running*, which for a
> one-shot service means it does **not** wait for it to finish. The `up` task follows with
> `docker compose wait bootstrap` so the data is guaranteed to be in place.

A sharding key needs enough cardinality to actually spread: the `bi` tables were first
keyed on `cityHash64(country_code)` and with only five countries every row hashed to shard
01, leaving shard 02 empty. They are keyed on `(day, country_code)` now.

## Repo split

The CLI image lives in its own repository:
**[`liquibase-clickhouse-image`](https://github.com/leonidgrishenkov/liquibase-clickhouse-image)**,
published to `public.ecr.aws/a8c0b5z6/liquibase-clickhouse`. It owns the Liquibase version,
the ClickHouse extension and the JDBC driver, and its README documents why each is pinned.

**This** repo is only the payload — changelogs and config — and consumes the image by tag.
There is deliberately no build task here. Every task that needs the image fails fast with
an actionable message when the tag is missing locally.

Getting a connection at all required working out three things, all documented in the image
repo:

1. **`clickhouse-jdbc:0.6.5-all` is a broken artifact** — missing `com.clickhouse.client`.
2. **`?compress=0` is required** in the JDBC URL, or every response fails with
   `IOException: Magic is not correct - expect [-126] but got [123]`.
3. **The image entrypoint always injects `--defaultsFile=/liquibase/liquibase.docker.properties`**,
   so `migrations/liquibase.properties` is mounted onto that path. `changelogFile` is
   resolved against `searchPath`, never as an absolute path.

## Configuration and precedence

`migrations/liquibase.properties` holds everything that is **not** a secret — the URL,
driver, search path, changelog path, tracking-table names. `compose.yaml` sets only
`LIQUIBASE_COMMAND_USERNAME` / `LIQUIBASE_COMMAND_PASSWORD`.

Mind the order: **environment variables outrank the defaults file**, so anything added to
the compose `environment:` block silently wins over the committed file. Liquibase will tell
you which source won at `--log-level=FINE`:

```
Found 'liquibase.command.url' configuration of 'jdbc:clickhouse://ch-s1r1:8123/liquibase?compress=0'
    environment variable 'LIQUIBASE_COMMAND_URL' of '*****'
    Overrides file exists at path /liquibase/liquibase.docker.properties 'url' of '*****'
```

That trace is the fastest way to answer "is this setting being ignored?".

### Liquibase's own tables

The extension creates them on first use, in the database named in the JDBC URL. Both come
out as plain `MergeTree ORDER BY ID`:

```sql
CREATE TABLE liquibase.DATABASECHANGELOG
(
    `ID` String, `AUTHOR` String, `FILENAME` String,
    `DATEEXECUTED` DateTime64(3), `ORDEREXECUTED` UInt64, `EXECTYPE` String,
    `MD5SUM` Nullable(String), `DESCRIPTION` Nullable(String), `COMMENTS` Nullable(String),
    `TAG` Nullable(String), `LIQUIBASE` Nullable(String), `CONTEXTS` Nullable(String),
    `LABELS` Nullable(String), `DEPLOYMENT_ID` Nullable(String)
)
ENGINE = MergeTree ORDER BY ID;
```

Table names are uppercase and ClickHouse is case-sensitive.

**Which database holds them.** Liquibase's usual knobs — `liquibaseCatalogName` /
`liquibaseSchemaName` — **hang** against ClickHouse. Liquibase accepts the value and logs
`Creating database changelog table with name: …`, then blocks forever in
`Creating snapshot`, because setting either makes it enumerate catalogs, which the v1
driver implements as a call to the ClickHouse **JDBC bridge**:

```sql
SELECT concat('jdbc(''', name, ''')') AS TABLE_CAT
FROM jdbc('...', 'SHOW DATASOURCES') ORDER BY name ASC
```

With no `clickhouse-jdbc-bridge` running, that query never returns; you have to kill the
container and `KILL QUERY` the stuck statement.

What works is **the database in the JDBC URL**, and nothing else. This repo points it at a
dedicated `liquibase` database so metadata stays out of the data schemas. Two consequences:

- **The database must already exist** — Liquibase creates the tracking tables but never the
  database. `clickhouse/initdb/00-databases.sql` creates it; keep the two in sync.
- **Every changeset must write fully-qualified DDL** (`${marts}orders_local`, never a bare
  `orders_local`). Unqualified names resolve against the connection database and would land
  in `liquibase`.

Because cluster mode is broken (see Findings), these tables are plain `MergeTree` and exist
**only on the node Liquibase connects to** — `ch-s1r1`. Always connect through the same
node; another node would show an empty migration history.

Only the table *names* are separately configurable, via `databaseChangeLogTableName` /
`databaseChangeLogLockTableName`.

## Migration conventions

```
migrations/changelog/clusters/<cluster>/<database>/sql/<UTC timestamp>_<name>.sql
```

**Per-cluster, per-database folders.** `db.changelog-root.yaml` holds the placeholders and
includes one changelog per cluster; each cluster includes one per database; each database
does an `includeAll` over its `sql/` folder. Dropping a file in is all that is needed —
no changelog editing.

**Timestamp prefixes** give deterministic ordering inside a folder, generated in **UTC** so
ordering does not depend on who ran the generator. ⚠️ Ordering is only total *within* a
`sql/` folder — across folders it follows the `include` order. A production repo of this
shape needed a dedicated "linearizer" to get global chronological order; that is a real
Liquibase limitation, not an oversight.

**Formatted SQL, not XML/YAML changesets.** ClickHouse DDL needs `ENGINE`, `ORDER BY`,
`PARTITION BY` and `ON CLUSTER`, none of which portable change types can express (see
Findings). The changelogs that *wire files together* are YAML; the changes themselves are
raw SQL.

**Placeholders** are defined in `db.changelog-root.yaml`:

| Placeholder | Expands to | Purpose |
|---|---|---|
| `${stage}` / `${bi}` / `${marts}` | `stage.` etc. | database prefix |
| `${personal_prefix}` | `""` | set to e.g. `leonid__` for a private sandbox copy |
| `${sharded}` | `'/clickhouse/tables/{shard}/{database}/{table}', '{replica}'` | per-shard `Replicated*MergeTree` args |
| `${broadcast}` | `'/clickhouse/tables/{shard_broadcast}/{database}/{table}', '{replica_broadcast}'` | cluster-wide copy |
| `${author_name}` | `deployer` | changeset author |

`{shard}` / `{replica}` are ClickHouse macros, not Liquibase ones — different substitution
mechanisms that happen to share brace syntax.

**Every changeset must carry an explicit `--rollback`.** Liquibase cannot invert raw SQL, so
a changeset without one fails at rollback time with
`RollbackImpossibleException: No inverse to liquibase.change.core.RawSQLChange created` —
and it fails on the *first* such changeset, so there is no partial rollback either. Where a
change genuinely cannot be undone, write `--rollback empty`, which is accepted and executes
as a no-op. The point is that every changeset records a *decision*.

Rollback SQL must be prefixed on **every** line. A bare `--rollback` followed by unprefixed
SQL does not open a block — it declares an empty rollback, and the following lines are read
as more *forward* SQL:

```sql
--rollback alter table ${marts}orders_local on cluster analytics_cluster
--rollback     drop column if exists is_test;
```

`task migrations:lint` enforces all of this — filename shape, the `--liquibase formatted
sql` header, one `--rollback` per changeset, `ON CLUSTER` matching the folder, and
`IF [NOT] EXISTS` guards on create/drop. It is a Taskfile recipe, not a helper script.

## Findings so far

**Applying migrations works, as long as you write raw SQL.** `ALTER TABLE … ON CLUSTER` on
a table Liquibase did not create lands on all four nodes, and `rollback-count` removes it
from all four. `status`, `history`, `validate`, `update-sql`, `rollback-count-sql` and
`changelog-sync-sql` all behave.

**Portable change types do not work.** Feeding Liquibase's own `createTable`:

```yaml
- createTable:
    tableName: feature_flags
    columns:
      - column: {name: flag_name, type: String}
      - column: {name: enabled, type: Bool}
      - column: {name: updated_at, type: DateTime}
```

makes it emit:

```sql
CREATE TABLE stage.feature_flags (flag_name STRING, enabled BOOLEAN, updated_at datetime)
```

Generic type spellings ClickHouse rejects (`Code: 50 … Unknown data type family: STRING`)
and, more fundamentally, **no `ENGINE` or `ORDER BY` clause at all** — so it could not
succeed even with the types fixed. Treat `<sql>` as the only usable change type here, which
gives up Liquibase's database portability entirely.

**`generate-changelog` is scoped to one database and loses the topology.** It only sees the
database in the JDBC URL, so pointed at `liquibase` it produces nothing at all; you have to
re-point the URL at each database in turn. It also fails outright by default — the snapshot
queries `information_schema.constraints`, which ClickHouse does not implement
(`Code: 60 … Unknown table expression identifier`) — so `task migrations:generate-changelog`
restricts it with `--diff-types=tables,columns`.

Run against `marts`, the output captures all four tables but:

- **Zero engine information.** No `ENGINE`, `ORDER BY`, `PARTITION BY`, sharding key or ZK
  path anywhere. `orders` (Distributed) and `orders_local` (ReplicatedMergeTree) come out
  **byte-identical** — the entire sharding and replication topology is gone.
- **Types are mangled**: `UInt64` → `UINT64(20)`, `UInt32` → `UINT32(10)`,
  `LowCardinality(String)` → `LOWCARDINALITY(String)`, `DateTime` → `datetime`.

The generated changelog is therefore **not round-trippable** — replaying it would create
eight plain tables with no replication. For adopting Liquibase on an existing ClickHouse
database, the realistic path is to hand-write a baseline changelog and run
`task migrations:changelog-sync`, which marks it applied without executing it.

**The extension's cluster mode is broken.** The extension reads
`liquibaseClickhouse.conf` for `clusterName` / `tableZooKeeperPathPrefix` /
`tableReplicaName`; without it, it logs `Cluster settings are not defined. Work in
single-instance clickhouse mode.` The file exists at `migrations/liquibaseClickhouse.conf`
but is **deliberately not mounted** — `task migrations:demo-cluster-mode` mounts it to show
why.

Cluster mode does take effect: the tracking tables come out as `ReplicatedMergeTree`
created with `ON CLUSTER`. But the changelog **lock is then acquired and never released**.
`release-locks` fails with `Did not update change log lock correctly.`, and every later run
blocks on `Waiting for changelog lock....` until the row is cleared by hand:

```sql
ALTER TABLE liquibase.DATABASECHANGELOGLOCK UPDATE LOCKED = 0, LOCKEDBY = null,
    LOCKGRANTED = null WHERE ID = 1 SETTINGS mutations_sync = 1;
```

That same statement issued manually works and completes (`system.mutations.is_done = 1`),
so ClickHouse is not at fault — it is the extension's lock handling under `ON CLUSTER`.
Cluster DDL is also slow: the two `CREATE TABLE … ON CLUSTER` statements took ~60s.

Worth noting the production repo this is modelled on *does* run cluster mode successfully,
on Liquibase **4.16** with a different extension build. So this is a regression in some
newer combination, not an inherent impossibility.

**Locking uses mutations.** `DATABASECHANGELOGLOCK` is acquired with
`ALTER TABLE … UPDATE … SETTINGS mutations_sync = 1`. ClickHouse mutations are not atomic
compare-and-swap, so the lock is advisory at best — worth keeping in mind before running
concurrent deploys.

## Layout

```
Taskfile.yml                               environment recipes; includes the one below
compose.yaml                               keeper + 4 ClickHouse nodes + bootstrap + liquibase

clickhouse/
  keeper/keeper_config.xml                 single Keeper node
  config.d/00-cluster.xml                  shared by all nodes: keeper, remote_servers
  macros/<node>.xml                        per-node shard/replica identity
  initdb/00-databases.sql                  the four databases
  initdb/01-tables.sql                     Replicated + Distributed fixture tables
  initdb/02-seed-data.sql                  idempotent seed INSERTs

migrations/
  taskfile.yaml                            all `task migrations:*` recipes
  liquibase.properties                     mounted as liquibase.docker.properties
  liquibaseClickhouse.conf                 extension cluster settings (NOT mounted; see Findings)
  changelog/
    db.changelog-root.yaml                 placeholders + one include per cluster
    clusters/<cluster>/changelog.yaml      one include per database
    clusters/<cluster>/<db>/changelog.yaml includeAll over sql/
    clusters/<cluster>/<db>/sql/*.sql      the migrations themselves
  out/                                     generate-changelog output (gitignored)
```

## Reusing this for Atlas

The ClickHouse side is tool-agnostic: `task nuke -y && task up` gives a fresh cluster with
the same schema and data, which is the fixture an Atlas comparison needs. Liquibase's
`DATABASECHANGELOG` / `DATABASECHANGELOGLOCK` in the `liquibase` database are the only
artifacts it leaves behind.
