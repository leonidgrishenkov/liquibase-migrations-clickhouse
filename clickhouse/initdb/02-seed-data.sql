-- A little data, so migrations run against non-empty tables.
INSERT INTO analytics.users (user_id, email, country_code, plan, is_active, signed_up_at) VALUES
    (1, 'ada@example.com',    'GB', 'enterprise', true,  '2025-01-14 09:00:00'),
    (2, 'grace@example.com',  'US', 'pro',        true,  '2025-03-02 17:30:00'),
    (3, 'linus@example.com',  'FI', 'free',       false, '2025-06-21 11:05:00');

INSERT INTO analytics.events (event_id, event_time, event_type, user_id, session_id, source_ip, properties, tags, revenue) VALUES
    (generateUUIDv4(), '2026-08-01 10:00:00.000', 'page_view', 1, NULL,             '10.0.0.1', {'path':'/pricing'}, ['web'],           0),
    (generateUUIDv4(), '2026-08-01 10:04:12.500', 'purchase',  1, generateUUIDv4(), '10.0.0.1', {'sku':'PRO-12M'},   ['web','billing'], 199.9900),
    (generateUUIDv4(), '2026-08-02 08:11:00.000', 'page_view', 2, NULL,             '10.0.0.2', {'path':'/docs'},    ['web'],           0);

INSERT INTO staging.events_raw (payload) VALUES ('{"event":"page_view"}');
