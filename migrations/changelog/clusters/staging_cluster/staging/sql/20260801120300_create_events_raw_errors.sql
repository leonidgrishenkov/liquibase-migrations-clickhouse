--liquibase formatted sql

--changeset ${author_name}:create_events_raw_errors
--comment: Second cluster, so the per-cluster folder split is actually exercised.
create table if not exists ${staging}events_raw_errors on cluster staging_cluster
(
    payload     String,
    error       String,
    ingested_at DateTime default now()
)
engine = ReplicatedMergeTree(${sharded})
order by ingested_at;
--rollback drop table if exists ${staging}events_raw_errors on cluster staging_cluster sync;
