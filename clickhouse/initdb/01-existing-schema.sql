-- Schema that already exists before any migration tool is pointed at this instance.
-- The point of the exercise: see what Liquibase (and later Atlas) make of it.

CREATE DATABASE IF NOT EXISTS analytics;

-- Plain MergeTree, monthly partitions, a TTL and a column codec.
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
ENGINE = MergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_type, user_id, event_time)
TTL toDateTime(event_time) + INTERVAL 2 YEAR
SETTINGS index_granularity = 8192;

-- ReplacingMergeTree with a version column and an Enum.
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
ENGINE = ReplacingMergeTree(updated_at)
ORDER BY user_id;

-- Aggregating rollup fed by a materialized view.
CREATE TABLE IF NOT EXISTS analytics.events_daily
(
    day          Date,
    event_type   LowCardinality(String),
    events       AggregateFunction(count, UInt64),
    unique_users AggregateFunction(uniq, UInt64),
    revenue      AggregateFunction(sum, Decimal(18, 4))
)
ENGINE = AggregatingMergeTree
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

-- Log-engine table: no MergeTree features at all, another shape to reverse-engineer.
CREATE TABLE IF NOT EXISTS analytics.import_audit
(
    imported_at DateTime DEFAULT now(),
    source      String,
    row_count   UInt64,
    ok          Bool
)
ENGINE = Log;

-- A second database, so cross-database handling gets exercised too.
CREATE DATABASE IF NOT EXISTS staging;

CREATE TABLE IF NOT EXISTS staging.events_raw
(
    payload    String,
    ingested_at DateTime DEFAULT now()
)
ENGINE = MergeTree
ORDER BY ingested_at;
