-- A little data, so migrations run against non-empty tables.
INSERT INTO staging.events_raw (payload) VALUES
    ('{"event":"page_view"}'),
    ('{"event":"purchase"}');

INSERT INTO staging.import_audit (source, row_count, ok) VALUES ('bootstrap', 2, true);
