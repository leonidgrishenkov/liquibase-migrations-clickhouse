--liquibase formatted sql

--changeset ${author_name}:test1
--comment: test changes
alter table ${analytics_schema}.users on cluster analytics_cluster
add column if not exists test_col String;

--rollback alter table ${analytics_schema}.users on cluster analytics_cluster drop column if exists test_col;
