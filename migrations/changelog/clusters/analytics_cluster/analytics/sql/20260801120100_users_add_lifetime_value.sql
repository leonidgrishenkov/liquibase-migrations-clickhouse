--liquibase formatted sql

--changeset ${author_name}:users_add_lifetime_value
--comment: Touches a table Liquibase did not create - the case this repo exists to test.
alter table ${analytics}users on cluster analytics_cluster
    add column if not exists lifetime_value Decimal(18, 4) default 0;
--rollback alter table ${analytics}users on cluster analytics_cluster drop column if exists lifetime_value;
