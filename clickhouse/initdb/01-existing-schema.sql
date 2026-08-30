-- Schema that already exists before any migration tool is pointed at this instance --
-- the fixture for "how does a migration tool cope with a database it did not create?".
--
-- Replicated* engines throughout, matching how a real ClickHouse cluster looks. No
-- ON CLUSTER on the tables: initdb runs while the server is still coming up and the
-- distributed DDL queue is not reliably available yet. On a single node the result is
-- identical. Migrations, which run against a fully started server, DO use ON CLUSTER.

CREATE DATABASE IF NOT EXISTS staging;

CREATE TABLE IF NOT EXISTS staging.events_raw
(
    payload     String,
    ingested_at DateTime DEFAULT now()
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/{database}/{table}', '{replica}')
ORDER BY ingested_at;

-- Log engine: cannot be replicated, deliberately left as an odd one out for tools that
-- try to reverse-engineer the schema.
CREATE TABLE IF NOT EXISTS staging.import_audit
(
    imported_at DateTime DEFAULT now(),
    source      String,
    row_count   UInt64,
    ok          Bool
)
ENGINE = Log;
