-- Database that holds Liquibase's own DATABASECHANGELOG / DATABASECHANGELOGLOCK,
-- kept apart from the schemas the migrations act on.
--
-- The connection database in the JDBC URL is the ONLY thing that controls where these
-- tables are created (liquibaseCatalogName / liquibaseSchemaName hang against ClickHouse
-- -- see README). Liquibase creates the tables but never the database, so it must exist
-- up front. Keep this in sync with `url:` in migrations/liquibase.properties.
CREATE DATABASE IF NOT EXISTS liquibase;
