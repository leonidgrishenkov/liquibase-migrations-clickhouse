# Liquibase on ClickHouse — test bed

A single-node ClickHouse 26.3.17.110 instance that comes up with a **pre-existing schema** (databases, tables, a
materialized view, seed rows), plus a Liquibase CLI container pointed at it. The question being tested: how does a
migration tool cope with a database it did not create?

Nothing is installed on the host — Liquibase runs from a container.

## Quick start

```bash
task image:build   # build the CLI image (stands in for `docker pull`)
task lint          # check migrations against the repo conventions
task update        # apply them - starts ClickHouse first
task tables        # look at the result
```

Authoring a change:

```bash
task new-migration NAME=create_orders CLUSTER=analytics_cluster DB=analytics
```

Every task depends on `up`, so ClickHouse is started for you. `task` on its own lists everything;
`task liquibase -- <args>` runs an arbitrary Liquibase command.

Requires [go-task](https://taskfile.dev).

## What is already in the database before Liquibase touches it

Created by `clickhouse/initdb/*.sql`, which the ClickHouse entrypoint runs once, on the first start of an empty data
volume (`task nuke` resets it; it prompts for confirmation, so add `-y` when scripting).

| Object | Engine | Why it's here |
| --- | --- | --- |
| `analytics.events` | ReplicatedMergeTree | Partitioning, TTL, a `CODEC`, `Map`/`Array`/`IPv4`/`LowCardinality` columns |
| `analytics.users` | ReplicatedReplacingMergeTree | Version column, `Enum8`, `FixedString` |
| `analytics.events_daily` | ReplicatedAggregatingMergeTree | `AggregateFunction` state columns |
| `analytics.events_daily_mv` | MaterializedView | An object type with no Liquibase equivalent |
| `analytics.import_audit` | Log | Non-MergeTree engine, cannot be replicated |
| `staging.events_raw` | ReplicatedMergeTree | A second database, on the second cluster |

## Repo split

The CLI image and the migrations are deliberately kept apart, as they would be in
practice:

- **`image/`** — stands in for a **separate repository** that builds and publishes
  `liquibase-clickhouse:4.33.0-1`. It owns the Liquibase version, the ClickHouse extension
  and the JDBC driver. See [`image/README.md`](image/README.md) for what is in it, why each
  version is pinned, and the contract it offers consumers.
- **`migrations/`** — this repo's actual payload: changelogs and `liquibase.properties`.
  It consumes the image **by tag** and never rebuilds it.

`compose.yaml` therefore has no `build:` for the Liquibase service — only
`image: ${LIQUIBASE_IMAGE:-liquibase-clickhouse:4.33.0-1}`. Point `LIQUIBASE_IMAGE` at a
registry copy (see `.env.example`) and `image/` becomes unnecessary here. Every migration
task fails fast with an actionable message if the tag is missing locally.

Getting a connection at all required working out three things; all three are part of the
image's consumer contract and documented in `image/README.md`:

1. **`clickhouse-jdbc:0.6.5-all` is a broken artifact** — missing `com.clickhouse.client`.
2. **`?compress=0` is required** in the JDBC URL, or every response fails with
   `IOException: Magic is not correct - expect [-126] but got [123]`.
3. **The image entrypoint always injects `--defaultsFile=/liquibase/liquibase.docker.properties`**,
   so `migrations/liquibase.properties` is mounted onto that path. `changelogFile` is
   resolved against `searchPath`, never as an absolute path.

### Liquibase's own tables

The extension creates them on first use, in the database named in the JDBC URL — no manual setup needed. Both come out
as plain `MergeTree ORDER BY ID`:

```sql
CREATE TABLE analytics.DATABASECHANGELOG
(
    `ID` String, `AUTHOR` String, `FILENAME` String,
    `DATEEXECUTED` DateTime64(3), `ORDEREXECUTED` UInt64, `EXECTYPE` String,
    `MD5SUM` Nullable(String), `DESCRIPTION` Nullable(String), `COMMENTS` Nullable(String),
    `TAG` Nullable(String), `LIQUIBASE` Nullable(String), `CONTEXTS` Nullable(String),
    `LABELS` Nullable(String), `DEPLOYMENT_ID` Nullable(String)
)
ENGINE = MergeTree ORDER BY ID;

CREATE TABLE analytics.DATABASECHANGELOGLOCK
(
    `ID` Int64, `LOCKED` UInt8,
    `LOCKGRANTED` Nullable(DateTime64(3)), `LOCKEDBY` Nullable(String)
)
ENGINE = MergeTree ORDER BY ID;
```

Note the table names are uppercase and ClickHouse is case-sensitive.

**Choosing which database holds them.** Liquibase's usual knobs for this are
`liquibaseCatalogName` / `liquibaseSchemaName` (`--liquibase-catalog-name`,
`--liquibase-schema-name`). ClickHouse has no catalog/schema split — a database is just a
database — and **both of these knobs hang**. Liquibase accepts the value and logs
`Creating database changelog table with name: liquibase_meta.DATABASECHANGELOG`, then
blocks forever in `Creating snapshot`, because setting either one makes it enumerate
catalogs, which the v1 driver implements as:

```sql
SELECT concat('jdbc(''', name, ''')') AS TABLE_CAT
FROM jdbc('...', 'SHOW DATASOURCES') ORDER BY name ASC
```

That is the ClickHouse **JDBC bridge** table function. With no `clickhouse-jdbc-bridge`
running, the query never returns and the tracking table is never created. You have to kill
the container and `KILL QUERY` the stuck statement.

What works instead is **the database in the JDBC URL** — the tracking tables always follow
the connection's database, and nothing else does:

```
LIQUIBASE_COMMAND_URL: jdbc:clickhouse://clickhouse:8123/liquibase_meta?compress=0
```

Verified: this puts `DATABASECHANGELOG`/`DATABASECHANGELOGLOCK` in `liquibase_meta` while
the changesets still act on `analytics`, because every changeset in this repo writes
fully-qualified DDL (`analytics.billing_invoices`, not `billing_invoices`). That
qualification stops being a style preference and becomes mandatory the moment the metadata
database and the target database differ.

Only the table *names* are separately configurable, via `databaseChangeLogTableName` /
`databaseChangeLogLockTableName` in `liquibase.properties`.

## Migration conventions

Modelled on a production ClickHouse migration repo, with one deliberate change (see
"rollbacks" below).

```
migrations/changelog/clusters/<cluster>/<database>/sql/<UTC timestamp>_<name>.sql
```

**Per-cluster folders.** `clusters/analytics_cluster/` and `clusters/staging_cluster/` are
*logical* ClickHouse clusters, not separate machines — both are defined in
`clickhouse/config.d/02-clusters.xml` and point at this one node. That is enough for
`ON CLUSTER` and `Replicated*MergeTree` to genuinely execute, so the folder split is real
rather than decorative. A single-node **embedded ClickHouse Keeper** backs the distributed
DDL queue.

**Timestamp prefixes** (`20260801120000_create_billing_invoices.sql`) give deterministic
ordering inside a folder. Generated in **UTC**, so ordering does not depend on who ran the
generator. ⚠️ Ordering is only total *within* a `sql/` folder — across folders it
follows the `include` order in the changelogs. A production repo of this shape needed a
dedicated "linearizer" to get global chronological order; that is a real Liquibase
limitation, not an oversight.

**Formatted SQL, not XML/YAML changesets.** ClickHouse DDL needs `ENGINE`, `ORDER BY`,
`PARTITION BY` and `ON CLUSTER`, none of which portable change types can express (see
Findings). The changelogs that *wire files together* are YAML; the changes themselves are
raw SQL.

**Placeholders** are defined in `changelog/db.changelog-root.yaml`:

| Placeholder | Expands to | Purpose |
|---|---|---|
| `${analytics}` / `${staging}` | `analytics.` / `staging.` | database prefix |
| `${personal_prefix}` | `""` | set to e.g. `leonid__` for a private sandbox copy |
| `${sharded}` | `'/clickhouse/tables/{shard}/{database}/{table}', '{replica}'` | `Replicated*MergeTree` args |
| `${author_name}` | `deployer` | changeset author |

`{shard}` / `{replica}` are ClickHouse macros, not Liquibase ones — different substitution
mechanisms that happen to share brace syntax.

**Every changeset must carry an explicit `--rollback`.** This is the deliberate addition.
Liquibase cannot invert raw SQL, so a changeset without one fails at rollback time with
`RollbackImpossibleException: No inverse to liquibase.change.core.RawSQLChange created` —
and it fails on the *first* such changeset, so there is no partial rollback either. Where a
change genuinely cannot be undone (`drop table`, `create or replace function` without the
previous body), write:

```sql
--rollback empty
```

which is accepted and executes as a no-op. The point is that every changeset records a
*decision*, so an irreversible change is distinguishable from an oversight.

`task lint` enforces all of this — filename shape, the `--liquibase formatted sql` header,
one `--rollback` per changeset, `ON CLUSTER` matching the folder, and `IF [NOT] EXISTS`
guards on create/drop. It is a Taskfile recipe, not a helper script.

## Findings so far

**Applying migrations works, as long as you write raw SQL.** All four changesets apply
cleanly across both clusters, including the two that alter tables Liquibase did not create
(`ALTER TABLE ... ADD COLUMN` on `users`, `ADD INDEX` on `events`), and including
`ON CLUSTER` DDL creating `Replicated*MergeTree` tables. Rolling all four back removes both
created tables and re-applying restores them. `status`, `history`, `validate`, `update-sql`
and `changelog-sync-sql` all behave.

**Portable change types do not work.** Feeding Liquibase's own `createTable` change type:

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
CREATE TABLE analytics.feature_flags (flag_name STRING, enabled BOOLEAN, updated_at datetime)
```

Generic type spellings ClickHouse rejects (`Code: 50 ... Unknown data type family: STRING`) and, more fundamentally,
**no `ENGINE` or `ORDER BY` clause at all** — so it could not succeed even with the types fixed. Treat `<sql>` as the
only usable change type here, which gives up Liquibase's database portability entirely.

**`generate-changelog` needs a workaround and is lossy anyway.** By default it fails: Liquibase's snapshot queries
`information_schema.constraints`, which ClickHouse does not implement
(`Code: 60 ... Unknown table expression identifier`). Restricting it with `--diff-types=tables,columns` (what
`task generate-changelog` does) produces output, but:

- **Every engine detail is gone** — no `ENGINE`, `ORDER BY`, `PARTITION BY`, `TTL`, codecs or `SETTINGS` anywhere in the
  file.
- **`import_audit` (Log) and the materialized view are missing entirely.**
- **Types are mangled**, in ways that are not just cosmetic: `UUID` → `char(36)`, `UInt64` → `UINT64(20)`, `String` →
  `STRING(0)`, `IPv4` → `IPV4(10)`, and parameterised types get truncated at the first comma —
  `Array(LowCardinality(String)`, `AggregateFunction(sum, Decimal(18)`. Worst of all, enums silently lose members:
  `Enum8('draft'=1,'sent'=2,'paid'=3,'void'=4)` came back as `ENUM8('draft' = 1, 'sent' = 2)`.

The generated changelog is therefore **not round-trippable** — it cannot recreate the schema it was generated from. For
adopting Liquibase on an existing ClickHouse database, the realistic path is to hand-write a baseline changelog and run
`task sync-baseline` (`changelog-sync`), which marks it applied without executing it.

**The extension's cluster mode is broken.** The extension reads
`liquibaseClickhouse.conf` for `clusterName` / `tableZooKeeperPathPrefix` /
`tableReplicaName`; without it, it logs `Cluster settings are not defined. Work in
single-instance clickhouse mode.` The file exists at `migrations/liquibaseClickhouse.conf`
but is **deliberately not mounted** — `task demo-cluster-mode` mounts it to show why.

Cluster mode does take effect: the tracking tables come out as
`ReplicatedMergeTree('/clickhouse/tables/{shard}/{database}/databasechangelog', '{replica}')`
created with `ON CLUSTER 'analytics_cluster'`. But the changelog **lock is then acquired and
never released**. `release-locks` fails with `Did not update change log lock correctly.`,
and every later run blocks on `Waiting for changelog lock....` until you clear the row by
hand:

```sql
ALTER TABLE analytics.DATABASECHANGELOGLOCK UPDATE LOCKED = 0, LOCKEDBY = null,
    LOCKGRANTED = null WHERE ID = 1 SETTINGS mutations_sync = 1;
```

The same statement issued manually works and completes (`system.mutations.is_done = 1`), so
ClickHouse is not at fault — it is the extension's lock handling under `ON CLUSTER`. Cluster
DDL is also slow here: the two `CREATE TABLE ... ON CLUSTER` statements took ~60s.

Worth noting the production repo this is modelled on *does* run in cluster mode
successfully, on Liquibase **4.16** with a different extension build. So this is a
regression in some newer combination, not an inherent impossibility.

**Locking uses mutations.** `DATABASECHANGELOGLOCK` is acquired with
`ALTER TABLE ... UPDATE ... SETTINGS mutations_sync = 1`. ClickHouse mutations are not atomic compare-and-swap, so the
lock is advisory at best — worth keeping in mind before running concurrent deploys against one cluster.

## Layout

```
Taskfile.yml                               task runner - `task` lists all targets
compose.yaml                               ClickHouse + Liquibase CLI container
clickhouse/initdb/01-existing-schema.sql   the pre-existing schema
clickhouse/initdb/02-seed-data.sql         seed rows
clickhouse/config.d/01-keeper.xml          embedded Keeper (needed for ON CLUSTER)
clickhouse/config.d/02-clusters.xml        two logical clusters on one node

image/                                     <- pretend this is another repo
  Dockerfile                               Liquibase 4.33 + extension + driver
  Taskfile.yml                             build / push (stands in for CI)
  README.md                                versions, pinning rationale, consumer contract

migrations/                                <- this repo's payload
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

The ClickHouse side is tool-agnostic: `task nuke && task up` gives a fresh instance with the same pre-existing schema,
which is the fixture an Atlas comparison needs. Liquibase's `DATABASECHANGELOG`/`DATABASECHANGELOGLOCK` tables are the
only artifacts it leaves behind.
