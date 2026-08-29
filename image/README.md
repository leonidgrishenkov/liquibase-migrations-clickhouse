# liquibase-clickhouse image

Liquibase with ClickHouse support baked in. Treat this directory as a **separate
repository**: it produces a versioned image, and migration repos consume that image
without ever rebuilding it.

```bash
task image:build                              # from the parent repo
docker build -t liquibase-clickhouse:4.33.0-1 .   # or directly
```

## What is in it and why

Liquibase has no first-party ClickHouse support — the official image ships neither a JDBC
driver nor a ClickHouse `Database` implementation, and `lpm search clickhouse` returns
nothing. This image adds the missing pieces to `/liquibase/lib`:

| Component | Version | Note |
|---|---|---|
| `liquibase/liquibase` | **4.33.0** | Pinned to 4.x — every published ClickHouse extension is built against Liquibase 4 and does not load under 5.x |
| `dev.crashteam:liquibase-clickhouse` | 0.8.3 | Community fork; the most recently published of the four on Maven Central |
| `com.clickhouse:clickhouse-jdbc` | 0.7.2 (`-all`) | Last of the v1 driver line, which is what the extension targets |
| `com.typesafe:config` | 1.4.3 | The extension jar is not shaded and needs this at runtime |

Each version is a build arg, so a consumer can override one without editing the Dockerfile:

```bash
docker build --build-arg CLICKHOUSE_JDBC_VERSION=0.7.1 -t liquibase-clickhouse:test .
```

Two traps are pinned deliberately and should not be "upgraded" casually:

- **`clickhouse-jdbc:0.6.5-all` is a broken artifact** — it contains the JDBC classes but
  not `com.clickhouse.client`, so the driver dies in its static initialiser with
  `NoClassDefFoundError: com/clickhouse/client/ClickHouseClient`.
- **Liquibase 5.x does not work** with any currently published ClickHouse extension.

## Contract for consumers

The image is a plain Liquibase CLI — arguments are passed straight through
(`docker run ... liquibase-clickhouse:4.33.0-1 update`). Three things a consumer repo has
to know:

1. **Config file path.** The upstream entrypoint always injects
   `--defaultsFile=/liquibase/liquibase.docker.properties` unless the command line already
   names one. Mount your properties file onto *that* path.
2. **`?compress=0` in the JDBC URL is mandatory.** The v1 driver decodes HTTP responses as
   LZ4 by default; recent ClickHouse replies uncompressed, which surfaces as
   `IOException: Magic is not correct - expect [-126] but got [123]`.
3. **`searchPath` + relative `changelogFile`.** An absolute `changelogFile` is not
   resolved as a filesystem path.

`/liquibase/out` exists and is writable, for `generate-changelog` output.

## Cluster mode

The extension looks for `liquibaseClickhouse.conf` and otherwise logs
`Cluster settings are not defined. Work in single-instance clickhouse mode.` For
`ON CLUSTER` / `ReplicatedMergeTree` deployments it wants `tableReplicaName`,
`clusterName` and `tableZooKeeperPathPrefix`. Mount that file in from the consumer repo —
it is deployment configuration, not part of the image.
