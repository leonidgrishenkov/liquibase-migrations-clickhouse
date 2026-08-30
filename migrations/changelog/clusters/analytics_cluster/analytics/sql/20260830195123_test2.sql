--liquibase formatted sql

--changeset ${author_name}:test2
--comment: new changes
alter table ${analytics_schema}.users on cluster analytics_cluster
add column if not exists test_col2 String;

--rollback alter table ${analytics_schema}.users on cluster analytics_cluster drop column if exists test_col2;


--changeset ${author_name}:test2-part2
--comment: new changes part2
alter table ${analytics_schema}.users on cluster analytics_cluster
add column if not exists test_col3 String;

--rollback alter table ${analytics_schema}.users on cluster analytics_cluster drop column if exists test_col3;
