-- Seed data, written through the Distributed tables so rows spread across both shards
-- by their sharding key.
--
-- Each INSERT is guarded by a scalar subquery on its own target, which makes the whole
-- file idempotent: the bootstrap container re-runs it on every `up`, and a second run
-- inserts nothing rather than duplicating rows.

INSERT INTO stage.users
SELECT
    number + 1                                                    AS user_id,
    concat('user', toString(number + 1), '@example.com')          AS email,
    ['GB', 'US', 'FI', 'DE', 'FR'][(number % 5) + 1]              AS country_code,
    toDateTime('2026-01-01 00:00:00') + (number * 3600)           AS signed_up_at
FROM numbers(150)
WHERE (SELECT count() FROM stage.users) = 0;

INSERT INTO stage.events
SELECT
    number + 1                                                    AS event_id,
    toDateTime('2026-08-01 00:00:00') + (number * 137)            AS event_time,
    ['page_view', 'click', 'purchase', 'signup'][(number % 4) + 1] AS event_type,
    (number % 150) + 1                                            AS user_id,
    concat('{"seq":', toString(number), '}')                      AS payload
FROM numbers(200)
WHERE (SELECT count() FROM stage.events) = 0;

INSERT INTO marts.orders
SELECT
    number + 1                                                    AS order_id,
    (number % 150) + 1                                            AS user_id,
    ['new', 'paid', 'shipped', 'refunded'][(number % 4) + 1]      AS status,
    toDecimal64(round(10 + (number % 500) * 1.37, 2), 2)          AS amount,
    toDateTime('2026-08-01 00:00:00') + (number * 611)            AS created_at
FROM numbers(180)
WHERE (SELECT count() FROM marts.orders) = 0;

INSERT INTO marts.order_items
SELECT
    (number % 180) + 1                                            AS order_id,
    concat('SKU-', leftPad(toString((number % 40) + 1), 3, '0'))  AS sku,
    (number % 5) + 1                                              AS qty,
    toDecimal64(round(5 + (number % 90) * 1.11, 2), 2)            AS price
FROM numbers(200)
WHERE (SELECT count() FROM marts.order_items) = 0;

INSERT INTO bi.daily_active_users
SELECT
    toDate('2026-08-01') + (number % 30)                          AS day,
    ['GB', 'US', 'FI', 'DE', 'FR'][(number % 5) + 1]              AS country_code,
    100 + (number * 7) % 900                                      AS users
FROM numbers(150)
WHERE (SELECT count() FROM bi.daily_active_users) = 0;

INSERT INTO bi.revenue_daily
SELECT
    toDate('2026-08-01') + (number % 30)                          AS day,
    ['GB', 'US', 'FI', 'DE', 'FR'][(number % 5) + 1]              AS country_code,
    toDecimal64(round(500 + (number % 400) * 9.13, 2), 2)         AS revenue
FROM numbers(150)
WHERE (SELECT count() FROM bi.revenue_daily) = 0;
