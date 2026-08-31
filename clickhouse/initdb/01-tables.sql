-- Schema that already exists before any migration tool is pointed at this cluster --
-- the fixture for "how does a migration tool cope with a database it did not create?".
--
-- Every table follows the standard two-object ClickHouse pattern:
--   <name>_local  ReplicatedMergeTree, the physical per-shard table
--   <name>        Distributed, the logical table you read and write
-- The ZooKeeper path uses {shard} so each shard owns its own slice; {replica} makes the
-- two replicas within a shard share it.

-- ---------------------------------------------------------------- stage (raw landing)
CREATE TABLE IF NOT EXISTS stage.events_local ON CLUSTER analytics_cluster
(
    event_id   UInt64,
    event_time DateTime,
    event_type LowCardinality(String),
    user_id    UInt64,
    payload    String
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/{database}/{table}', '{replica}')
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_type, user_id, event_time);

CREATE TABLE IF NOT EXISTS stage.events ON CLUSTER analytics_cluster
AS stage.events_local
ENGINE = Distributed(analytics_cluster, stage, events_local, cityHash64(user_id));

CREATE TABLE IF NOT EXISTS stage.users_local ON CLUSTER analytics_cluster
(
    user_id      UInt64,
    email        String,
    country_code LowCardinality(String),
    signed_up_at DateTime
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/{database}/{table}', '{replica}')
ORDER BY user_id;

CREATE TABLE IF NOT EXISTS stage.users ON CLUSTER analytics_cluster
AS stage.users_local
ENGINE = Distributed(analytics_cluster, stage, users_local, cityHash64(user_id));

-- ------------------------------------------------------------------- marts (modelled)
CREATE TABLE IF NOT EXISTS marts.orders_local ON CLUSTER analytics_cluster
(
    order_id   UInt64,
    user_id    UInt64,
    status     LowCardinality(String),
    amount     Decimal(18, 2),
    created_at DateTime
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/{database}/{table}', '{replica}')
PARTITION BY toYYYYMM(created_at)
ORDER BY (user_id, order_id);

CREATE TABLE IF NOT EXISTS marts.orders ON CLUSTER analytics_cluster
AS marts.orders_local
ENGINE = Distributed(analytics_cluster, marts, orders_local, cityHash64(user_id));

CREATE TABLE IF NOT EXISTS marts.order_items_local ON CLUSTER analytics_cluster
(
    order_id UInt64,
    sku      LowCardinality(String),
    qty      UInt32,
    price    Decimal(18, 2)
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/{database}/{table}', '{replica}')
ORDER BY (order_id, sku);

CREATE TABLE IF NOT EXISTS marts.order_items ON CLUSTER analytics_cluster
AS marts.order_items_local
ENGINE = Distributed(analytics_cluster, marts, order_items_local, cityHash64(order_id));

-- ------------------------------------------------------------------ bi (presentation)
-- Sharding key is (day, country_code), not country_code alone: with only five distinct
-- countries every row hashed to the same shard, leaving shard 02 empty.
CREATE TABLE IF NOT EXISTS bi.daily_active_users_local ON CLUSTER analytics_cluster
(
    day          Date,
    country_code LowCardinality(String),
    users        UInt64
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/{database}/{table}', '{replica}')
ORDER BY (day, country_code);

CREATE TABLE IF NOT EXISTS bi.daily_active_users ON CLUSTER analytics_cluster
AS bi.daily_active_users_local
ENGINE = Distributed(analytics_cluster, bi, daily_active_users_local, cityHash64(day, country_code));

CREATE TABLE IF NOT EXISTS bi.revenue_daily_local ON CLUSTER analytics_cluster
(
    day          Date,
    country_code LowCardinality(String),
    revenue      Decimal(18, 2)
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/{database}/{table}', '{replica}')
ORDER BY (day, country_code);

CREATE TABLE IF NOT EXISTS bi.revenue_daily ON CLUSTER analytics_cluster
AS bi.revenue_daily_local
ENGINE = Distributed(analytics_cluster, bi, revenue_daily_local, cityHash64(day, country_code));
