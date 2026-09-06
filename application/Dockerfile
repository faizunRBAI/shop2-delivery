# syntax=docker/dockerfile:1

# --- Build stage -----------------------------------------------------------
FROM maven:3.9.9-eclipse-temurin-21 AS build
WORKDIR /build

# Dependency layer first: re-resolved only when the POM actually changes.
COPY pom.xml .
RUN mvn -B -ntp dependency:go-offline

COPY src ./src
RUN mvn -B -ntp -DskipTests clean package

# --- Runtime stage ---------------------------------------------------------
FROM eclipse-temurin:21-jre-noble

# MaxRAMPercentage keeps the JVM heap inside the container memory limit set by
# the Helm chart; without it the JVM sizes against the node, not the cgroup.
ENV JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=75.0"
ENV SERVER_PORT=8080

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --system --gid 10001 shopfast \
 && useradd --system --uid 10001 --gid shopfast --home-dir /app --shell /usr/sbin/nologin shopfast \
 && mkdir -p /app \
 && chown shopfast:shopfast /app

WORKDIR /app
COPY --from=build --chown=shopfast:shopfast /build/target/shopfast.jar /app/app.jar

USER shopfast
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=45s --retries=3 \
  CMD curl -fsS http://127.0.0.1:8080/actuator/health || exit 1

# Exec form: the JVM is PID 1 and receives SIGTERM directly, so Spring Boot's
# graceful shutdown runs when Argo Rollouts scales down a ReplicaSet.
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
