# Liquibase on ClickHouse — test bed

A single-node ClickHouse 26.3.17.110 instance that comes up with a **pre-existing schema** (databases, tables, a
materialized view, seed rows), plus a Liquibase CLI container pointed at it. The question being tested: how does a
migration tool cope with a database it did not create?

Nothing is installed on the host — Liquibase runs from a container.

## Quick start

```bash
task build     # Liquibase image (only needed once)
task update    # apply the changelog - starts ClickHouse first
task tables    # look at the result
```

Every task depends on `up`, so ClickHouse is started for you. `task` on its own lists everything;
`task liquibase -- <args>` runs an arbitrary Liquibase command.

Requires [go-task](https://taskfile.dev).

## What is already in the database before Liquibase touches it

Created by `clickhouse/initdb/*.sql`, which the ClickHouse entrypoint runs once, on the first start of an empty data
volume (`task nuke` resets it; it prompts for confirmation, so add `-y` when scripting).

| Object                      | Engine               | Why it's here                                                               |
| --------------------------- | -------------------- | --------------------------------------------------------------------------- |
| `analytics.events`          | MergeTree            | Partitioning, TTL, a `CODEC`, `Map`/`Array`/`IPv4`/`LowCardinality` columns |
| `analytics.users`           | ReplacingMergeTree   | Version column, `Enum8`, `FixedString`                                      |
| `analytics.events_daily`    | AggregatingMergeTree | `AggregateFunction` state columns                                           |
| `analytics.events_daily_mv` | MaterializedView     | An object type with no Liquibase equivalent                                 |
| `analytics.import_audit`    | Log                  | Non-MergeTree engine                                                        |
| `staging.events_raw`        | MergeTree            | A second database                                                           |

## How Liquibase is wired up

Liquibase has **no first-party ClickHouse support**. The official image ships neither a JDBC driver nor a ClickHouse
`Database` implementation, and `lpm search clickhouse` returns nothing. `liquibase/Dockerfile` layers three jars into
`/liquibase/lib`:

| Jar                                  | Version        | Note                                                                                                                                           |
| ------------------------------------ | -------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| `liquibase/liquibase`                | **4.33.0**     | Pinned to 4.x — every published ClickHouse extension is built against Liquibase 4 and does not load under 5.x                                  |
| `dev.crashteam:liquibase-clickhouse` | 0.8.3          | Community fork; the most recently published of the four on Maven Central (`io.goodforgod`, `io.arenadata`, `com.mediarithmics` are the others) |
| `com.clickhouse:clickhouse-jdbc`     | 0.7.2 (`-all`) | Last of the v1 driver line, which is what the extension targets                                                                                |
| `com.typesafe:config`                | 1.4.3          | The extension jar is not shaded and needs this at runtime                                                                                      |

Three things had to be worked out to get a connection at all — each is commented at the place it matters:

1. **`clickhouse-jdbc:0.6.5-all` is a broken artifact.** It contains the JDBC classes but not `com.clickhouse.client`,
   so the driver dies in its static initialiser with `NoClassDefFoundError: com/clickhouse/client/ClickHouseClient`.
   0.7.2's `-all` is fine.
2. **`?compress=0` is required.** The v1 driver decodes HTTP responses as LZ4 by default; ClickHouse 26.3 replies
   uncompressed, which surfaces as the very unhelpful `IOException: Magic is not correct - expect [-126] but got [123]`
   (`123` is `{` — the start of a plain JSON body).
3. **The image entrypoint always injects `--defaultsFile=/liquibase/liquibase.docker.properties`**, so
   `liquibase.properties` is mounted onto _that_ path. `changelogFile` is resolved against `searchPath`, never as an
   absolute path.

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

## Findings so far

**Applying migrations works, as long as you write raw SQL.** All three changesets in `liquibase/changelog/changes/`
applied cleanly, including the two that alter tables Liquibase did not create (`ALTER TABLE ... ADD COLUMN` on `users`,
`ADD INDEX` on `events`). `rollback-count` reverses them correctly. `status`, `history`, `validate`, `update-sql` and
`changelog-sync-sql` all behave.

**Portable change types do not work.** `task demo-portable` runs a `<createTable>` and Liquibase emits:

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

**Locking uses mutations.** `DATABASECHANGELOGLOCK` is acquired with
`ALTER TABLE ... UPDATE ... SETTINGS mutations_sync = 1`. ClickHouse mutations are not atomic compare-and-swap, so the
lock is advisory at best — worth keeping in mind before running concurrent deploys against one cluster.

## Layout

```
Taskfile.yml                              task runner - `task` lists all targets
compose.yaml                              ClickHouse + Liquibase CLI container
clickhouse/initdb/01-existing-schema.sql  the pre-existing schema
clickhouse/initdb/02-seed-data.sql        seed rows
liquibase/Dockerfile                      Liquibase 4.33 + extension + driver
liquibase/liquibase.properties            mounted as liquibase.docker.properties
liquibase/changelog/db.changelog-root.yaml
liquibase/changelog/changes/              changesets applied by `task update`
liquibase/changelog/experiments/          changelogs that are expected to fail
liquibase/out/                            generate-changelog output (gitignored)
```

## Reusing this for Atlas

The ClickHouse side is tool-agnostic: `task nuke && task up` gives a fresh instance with the same pre-existing schema,
which is the fixture an Atlas comparison needs. Liquibase's `DATABASECHANGELOG`/`DATABASECHANGELOGLOCK` tables are the
only artifacts it leaves behind.
