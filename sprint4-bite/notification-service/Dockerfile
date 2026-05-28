# syntax=docker/dockerfile:1
# ── Build stage ───────────────────────────────────────────────────────────────
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /build
COPY pom.xml .
RUN mvn -B -q dependency:go-offline
COPY src ./src
RUN mvn -B -q -DskipTests package

# ── Runtime stage ─────────────────────────────────────────────────────────────
FROM eclipse-temurin:21-jre-noble
WORKDIR /app
COPY --from=build /build/target/notification-service.jar /app/app.jar
EXPOSE 8003
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
