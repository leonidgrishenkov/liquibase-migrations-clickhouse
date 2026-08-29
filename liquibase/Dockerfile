# Liquibase has no first-party ClickHouse support: the CLI image ships neither the
# JDBC driver nor a ClickHouse Database implementation, and `lpm search clickhouse`
# comes back empty. Both have to be dropped into /liquibase/lib by hand.
#
# Pinned to 4.x on purpose - every published liquibase-clickhouse extension is built
# against Liquibase 4 (this one against 4.24) and does not load under Liquibase 5.
FROM liquibase/liquibase:4.33.0

USER root

ARG CLICKHOUSE_JDBC_VERSION=0.7.2
ARG LIQUIBASE_CLICKHOUSE_VERSION=0.8.3
# The extension jar is not shaded and needs its own compile deps at runtime.
# snakeyaml/slf4j already ship with Liquibase; typesafe config does not.
ARG TYPESAFE_CONFIG_VERSION=1.4.3
ARG MAVEN=https://repo1.maven.org/maven2

# "-all" is the self-contained driver: JDBC + client + Apache HttpClient 5 in one jar.
# Do not "upgrade" to 0.6.5-all - that build is missing com.clickhouse.client entirely
# and dies with NoClassDefFoundError: com/clickhouse/client/ClickHouseClient.
# 0.7.x is also the last v1-line driver, which is what the extension was built against.
RUN curl -fsSL -o /liquibase/lib/clickhouse-jdbc.jar \
      "${MAVEN}/com/clickhouse/clickhouse-jdbc/${CLICKHOUSE_JDBC_VERSION}/clickhouse-jdbc-${CLICKHOUSE_JDBC_VERSION}-all.jar" \
 && curl -fsSL -o /liquibase/lib/liquibase-clickhouse.jar \
      "${MAVEN}/dev/crashteam/liquibase-clickhouse/${LIQUIBASE_CLICKHOUSE_VERSION}/liquibase-clickhouse-${LIQUIBASE_CLICKHOUSE_VERSION}.jar" \
 && curl -fsSL -o /liquibase/lib/typesafe-config.jar \
      "${MAVEN}/com/typesafe/config/${TYPESAFE_CONFIG_VERSION}/config-${TYPESAFE_CONFIG_VERSION}.jar"

RUN mkdir -p /liquibase/out && chown -R liquibase:liquibase /liquibase/lib /liquibase/out

USER liquibase
