--liquibase formatted sql

--changeset ${author_name}:events_add_skip_index
--comment: ClickHouse-specific DDL that no portable Liquibase change type covers.
alter table ${analytics}events on cluster analytics_cluster
    add index if not exists idx_user_id user_id type minmax granularity 4;
--rollback alter table ${analytics}events on cluster analytics_cluster drop index if exists idx_user_id;
