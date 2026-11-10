# DevSecOps Phase 1 - multi-stage build.
# Written and linted in Phase 1 (hadolint). Built and scanned with Trivy in Phase 2,
# when Docker is installed in the VM.

# ---------- build stage ----------
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /build
COPY pom.xml ./
# Dependencies are resolved in their own layer so source changes do not refetch them.
RUN mvn -B -ntp dependency:go-offline
COPY src ./src
RUN mvn -B -ntp package -DskipTests

# ---------- runtime stage ----------
FROM eclipse-temurin:21-jre-alpine
# Run as an unprivileged, numeric user (numeric so the host can always resolve it).
RUN addgroup -S -g 10001 app \
    && adduser -S -u 10001 -G app -h /app -s /sbin/nologin app
WORKDIR /app
COPY --from=build --chown=10001:10001 /build/target/*.jar /app/app.jar
USER 10001:10001
EXPOSE 8080
# busybox wget is part of the alpine base image; no extra package needed.
HEALTHCHECK --interval=30s --timeout=5s --start-period=45s --retries=3 \
    CMD ["wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/hello"]
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
