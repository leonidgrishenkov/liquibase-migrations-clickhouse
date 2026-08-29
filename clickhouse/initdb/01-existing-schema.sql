-- Schema that already exists before any migration tool is pointed at this instance.
-- The point of the exercise: see what Liquibase (and later Atlas) make of it.
--
-- Replicated* engines are used throughout, matching how a real ClickHouse cluster looks.
-- No ON CLUSTER here: initdb runs while the server is still coming up and the distributed
-- DDL queue is not reliably available yet. On a single node the result is identical.
-- Migrations, which run against a fully started server, DO use ON CLUSTER.

CREATE DATABASE IF NOT EXISTS analytics;

CREATE TABLE IF NOT EXISTS analytics.events
(
    event_id     UUID,
    event_time   DateTime64(3, 'UTC'),
    event_type   LowCardinality(String),
    user_id      UInt64,
    session_id   Nullable(UUID),
    source_ip    IPv4,
    properties   Map(String, String),
    tags         Array(LowCardinality(String)),
    revenue      Decimal(18, 4) DEFAULT 0,
    created_at   DateTime DEFAULT now() CODEC(Delta, ZSTD(1))
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/{database}/{table}', '{replica}')
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_type, user_id, event_time)
TTL toDateTime(event_time) + INTERVAL 2 YEAR
SETTINGS index_granularity = 8192;

CREATE TABLE IF NOT EXISTS analytics.users
(
    user_id      UInt64,
    email        String,
    country_code LowCardinality(FixedString(2)),
    plan         Enum8('free' = 1, 'pro' = 2, 'enterprise' = 3),
    is_active    Bool DEFAULT true,
    signed_up_at DateTime,
    updated_at   DateTime DEFAULT now()
)
ENGINE = ReplicatedReplacingMergeTree('/clickhouse/tables/{shard}/{database}/{table}', '{replica}', updated_at)
ORDER BY user_id;

CREATE TABLE IF NOT EXISTS analytics.events_daily
(
    day          Date,
    event_type   LowCardinality(String),
    events       AggregateFunction(count, UInt64),
    unique_users AggregateFunction(uniq, UInt64),
    revenue      AggregateFunction(sum, Decimal(18, 4))
)
ENGINE = ReplicatedAggregatingMergeTree('/clickhouse/tables/{shard}/{database}/{table}', '{replica}')
ORDER BY (day, event_type);

CREATE MATERIALIZED VIEW IF NOT EXISTS analytics.events_daily_mv TO analytics.events_daily AS
SELECT
    toDate(event_time)      AS day,
    event_type,
    countState()            AS events,
    uniqState(user_id)      AS unique_users,
    sumState(revenue)       AS revenue
FROM analytics.events
GROUP BY day, event_type;

-- Log engine: cannot be replicated, deliberately left as an odd one out.
CREATE TABLE IF NOT EXISTS analytics.import_audit
(
    imported_at DateTime DEFAULT now(),
    source      String,
    row_count   UInt64,
    ok          Bool
)
ENGINE = Log;

-- A second database, on the second logical cluster.
CREATE DATABASE IF NOT EXISTS staging;

CREATE TABLE IF NOT EXISTS staging.events_raw
(
    payload     String,
    ingested_at DateTime DEFAULT now()
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/{database}/{table}', '{replica}')
ORDER BY ingested_at;
