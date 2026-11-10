# Threat model — jenkins-test Spring Boot API

**Phase 1 (Development) deliverable.** One-page STRIDE model of the REST API and the
pipeline that builds it. Kept deliberately small: this application is a course
project, not a production service.

## Scope

| Item | Value |
|---|---|
| Application | Spring Boot 4.1.2 web app, packaged as a jar, containerised in Phase 2 |
| Interfaces | `GET /hello` (public greeting), `POST /api/items` (JSON body, validated) |
| Runtime | Java 21, embedded Tomcat on port 8080 |
| Build path | Git repository → Jenkins `pipeline-git` → jar |
| Out of scope (Phase 1) | Database, authentication/login, hosted production infrastructure |

## Assets

1. **Source code and build files** — integrity of `src/`, `pom.xml`, `Dockerfile`, `Jenkinsfile`.
2. **Build credentials** — GitHub access token, SonarQube token, NVD API key (held in Jenkins).
3. **Application configuration** — `APP_API_KEY`, `APP_GREETING`, port settings.
4. **Pipeline artefacts** — test, scan and quality reports used as evidence.
5. **Availability of the API** — the service answering on port 8080.

## Entry points and trust boundaries

| Entry point | Trust boundary |
|---|---|
| HTTP requests to `:8080` (`/hello`, `/api/items`) | Untrusted client → application |
| Request body JSON of `POST /api/items` | Untrusted input → validation layer |
| Git push to the repository | Developer machine → CI |
| `Jenkinsfile` executed by Jenkins | Repository content → build agent |
| Container image built from `Dockerfile` (Phase 2) | Build output → runtime |

## STRIDE

| STRIDE | Threat in this application | Mitigation implemented in Phase 1 |
|---|---|---|
| **S**poofing | A client pretends to be another caller; a commit pretends to come from another author. | Public greeting endpoint only; no identity claims are trusted by the API yet. Git author identity verified at the platform level; `Jenkinsfile` and `Dockerfile` changes are reviewed before merge. |
| **T**ampering | Altered request body injects unexpected fields or oversized values; a modified dependency enters the build. | Bean Validation on `ItemRequest` (`@NotBlank`, `@Size(max=20)`, `@Min(1)`); unknown or malformed JSON rejected with HTTP 400; dependency scan (OWASP Dependency-Check) fails the build on CVSS ≥ 9. |
| **R**epudiation | No record of who changed the pipeline or what each build scanned. | Every change goes through Git and a branch (never direct to `main`); Jenkins keeps console logs, timestamps and archived reports per build. |
| **I**nformation disclosure | Stack traces, exception types or internal messages returned to the client; secrets committed to the repository. | Errors answered with status + generic message only, detail logged server-side (`ApiExceptionHandler`, `server.error.include-*=never`); no secret hardcoded — values come from environment variables (`application.properties` + `.env.example`); Gitleaks scan in CI and a pre-commit hook locally. |
| **D**enial of service | Huge or deeply nested JSON body; unbounded request size. | `@Size(max=20)` on `name`, numeric bounds via `@Min(1)`; malformed bodies rejected early with 400. Body-size limits and rate limiting are **not** implemented — accepted risk for a course project, noted here rather than silently ignored. |
| **E**levation of privilege | Container process runs as root; pipeline executes untrusted repository code with broad credentials. | `Dockerfile` runs as a non-root `app` user (created in the image); Jenkins credentials are scoped to this job and are not printed to logs. |
| **S**poofing (build) | A pull request executes a modified `Jenkinsfile`. | Only reviewed branches are built; `main` is protected by review on merge. |

## Residual risks / accepted for this exercise

- No authentication or authorisation on the API — out of scope for Phase 1.
- No TLS termination and no rate limiting — deferred to Production/Operations phases.
- SonarQube SAST is opt-in (`RUN_SONAR`, default `false`) because the server is not installed yet.
- NVD data for Dependency-Check is downloaded from NIST on first run; a stale cache is a detection
  gap, mitigated by the weekly Jenkins job that refreshes it.
