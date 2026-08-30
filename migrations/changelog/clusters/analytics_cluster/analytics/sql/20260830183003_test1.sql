--liquibase formatted sql

--changeset ${author_name}:test1
--comment: TODO: describe this change
create table if not exists ${analytics}<table_name> on cluster analytics_cluster
(
    -- columns here
)
engine = ReplicatedMergeTree(${sharded})
order by (<sort_key>);
--rollback drop table if exists ${analytics}<table_name> on cluster analytics_cluster sync;
