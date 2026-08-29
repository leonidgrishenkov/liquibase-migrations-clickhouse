--liquibase formatted sql

--changeset ${author_name}:create_billing_invoices
--comment: New table alongside the pre-existing analytics schema.
create table if not exists ${analytics}billing_invoices on cluster analytics_cluster
(
    invoice_id  UUID,
    user_id     UInt64,
    issued_at   DateTime,
    amount      Decimal(18, 4),
    currency    LowCardinality(String),
    status      Enum8('draft' = 1, 'sent' = 2, 'paid' = 3, 'void' = 4),
    updated_at  DateTime default now()
)
engine = ReplicatedReplacingMergeTree(${sharded}, updated_at)
partition by toYYYYMM(issued_at)
order by (user_id, issued_at, invoice_id);
--rollback drop table if exists ${analytics}billing_invoices on cluster analytics_cluster sync;
