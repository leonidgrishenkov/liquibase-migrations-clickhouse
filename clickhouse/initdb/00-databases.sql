-- Every database that must exist before Liquibase runs. Liquibase creates tables, but
-- never databases, so anything a migration targets has to be created here first.

-- Holds Liquibase's own DATABASECHANGELOG / DATABASECHANGELOGLOCK, kept apart from the
-- schemas the migrations act on. The connection database in the JDBC URL is the ONLY
-- thing that controls where these tables land (liquibaseCatalogName /
-- liquibaseSchemaName hang against ClickHouse -- see README). Keep this in sync with
-- `url:` in migrations/liquibase.properties.
CREATE DATABASE IF NOT EXISTS liquibase;

-- Databases on analytics_cluster that the migrations target. Each has a matching
-- folder under migrations/changelog/clusters/analytics_cluster/.
CREATE DATABASE IF NOT EXISTS bi    ON CLUSTER analytics_cluster;
CREATE DATABASE IF NOT EXISTS marts ON CLUSTER analytics_cluster;
CREATE DATABASE IF NOT EXISTS stage ON CLUSTER analytics_cluster;
