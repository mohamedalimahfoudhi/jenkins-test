# Final validation guide — four phases, one Jenkins job

This is the manual validation script for the project: what to run, in what order, what
to expect, and how to tell a real PASS from a green-looking FAIL.

Read §0 first. Everything below is written so that each claim can be checked against a
console line or an artifact, never against an impression.

> **Status of this document.** The pipeline, scripts and configuration described here are
> statically validated (§12 of the project audit) but **not** re-executed for this
> revision. Phase 2 was previously exercised by Jenkins build #11; Phase 3 and Phase 4
> have not been executed on the VM. Nothing in this guide is a claim that a stage passed.

---

## 0. Scope and safety

* "Production" in this project is a **second local container** on the same VM, on port
  18081. There is no remote host, no registry push, no real production system.
* **Never point this pipeline at a real production environment.** `devsecops-demo:ci`
  runs with a throw-away secret, publishes a debug port, and the `post` block deletes
  its containers at the end of every build.
* Monitoring is a local demo stack. Only Grafana (3000) is published on all interfaces,
  because it is the UI a reviewer opens from outside the VM; Prometheus (9090),
  Alertmanager (9093) and node_exporter (9100) are bound to `127.0.0.1`. If you do not
  need Grafana from another machine, reach it over an SSH tunnel instead of opening it.
* The pipeline deletes `devsecops-app` and `devsecops-prod` at the end of **every**
  build, including failed ones. A build that finishes with no application container
  running is a success, not a failure.

---

## 1. Prerequisites

### 1.1 Jenkins configuration (must exist before the first build)

| Item | Exact value | Where |
|---|---|---|
| JDK tool | name `jdk21` | Manage Jenkins → Tools |
| Maven tool | name `maven` | Manage Jenkins → Tools |
| Credential | ID `nvd-api-key`, kind **Secret text** | Manage Jenkins → Credentials |
| Credential | ID `app-api-key`, kind **Secret text** | Manage Jenkins → Credentials |
| Plugins | Pipeline, Git, Credentials Binding, JUnit, HTML Publisher, Timestamper | Manage Jenkins → Plugins |
| Optional | SonarQube server named `SonarQube` (only if `RUN_SONAR` is ticked) | Manage Jenkins → System |

The credential IDs are written literally in the Jenkinsfile. Do not create variants with
different casing or spacing. Neither value may be committed, pasted into the repository,
or set as a build parameter.

`app-api-key` must hold a **real-looking value** — anything except the placeholder
`replace-me`. `config-safety-check.sh` fails the build when the container carries the
placeholder, which is the point of that check.

### 1.2 VM prerequisites (Ubuntu 22.04, 4 GB RAM)

| Requirement | Check | Installer |
|---|---|---|
| Jenkins on 8080 | `systemctl status jenkins` | — |
| Docker reachable by the `jenkins` user | `sudo -u jenkins docker info` | `sudo bash scripts/install-phase2.sh` |
| `gitleaks`, `hadolint`, `trivy`, `python3`, `curl`, `ss` | `command -v <tool>` | `sudo bash scripts/install-tools.sh` (plus `apt-get install -y curl` if absent) |
| Docker Compose v2 (Phase 4 only) | `docker compose version` | ships with Docker CE from `install-phase2.sh` |
| Dependency-Check CLI | `ls /opt/dependency-check/bin/dependency-check.sh` | `sudo bash scripts/install-dependency-check.sh` |
| Swap on a 4 GB box | `swapon --show` | `sudo bash scripts/add-swap.sh` |
| Host hardening (ufw, fail2ban) | `sudo ufw status` | `sudo bash scripts/install-phase3.sh` |

`Preflight (tool checks)` reports each of these before any stage runs, so a missing
binary is one clear `FAIL` line rather than a mysterious red security stage.

### 1.3 Job definition

* Type: **Pipeline**, "Pipeline script from SCM", Git, repository
  `https://github.com/mohamedalimahfoudhi/jenkins-test`, script path `Jenkinsfile`.
* Branch: `*/nvd-credential-diagnostic` (or `*/devsecops-final`).
* Build with Parameters enabled (it is automatic once the Jenkinsfile declares
  `parameters {}`).

---

## 2. The 14 parameters

| Parameter | Default | Phase | What it runs |
|---|---|---|---|
| `RUN_SONAR` | false | 1 | SonarQube SAST + quality gate (≈ 2 GB RAM) |
| `RUN_DEPENDENCY_CHECK` | true | 1 | OWASP Dependency-Check, gate `--failOnCVSS 9` |
| `RUN_TRIVY_FS` | true | 1 | Trivy fs on the resolved dependencies, gate CRITICAL |
| `BUILD_IMAGE` | true | 2 | Builds `devsecops-demo:ci` |
| `TRIVY_SCAN` | true | 2 | Trivy image scan, gate CRITICAL |
| `DEPLOY_CONTAINER` | true | 2 | Runs `devsecops-app` on 18080 |
| `ZAP_SCAN` | true | 2 | OWASP ZAP baseline against the container (≈ 1 GB RAM) |
| `ACCEPTANCE_TESTS` | true | 2 | `security-acceptance-test.sh` (11 checks) |
| `INFRA_TEST` | true | 2 | `infra-check.sh` (VM state) |
| `COMPLIANCE_CHECK` | true | 2 | `compliance-check.sh` (9 checks) |
| `PROD_DEPLOY` | **false** | 3 | Runs `devsecops-prod` on 18081 with `app-api-key` injected |
| `SECURITY_SMOKE` | true | 3 | `security-smoke-test.sh` (13 checks) |
| `CONFIG_SAFETY` | true | 3 | `config-safety-check.sh` (8 checks) |
| `MONITORING` | **false** | 4 | Prometheus/Alertmanager/Grafana/node_exporter + `monitoring-check.sh` (14 checks) |

Untick every parameter you do not want: most default to `true`, so a phase-specific
build must set the other phases to `false` explicitly.

---

## 3. Parameter sets per phase — copy these

Run the phases in the order 1 → 2 → 3 → 4. A phase can be repeated; it cannot be reordered
meaningfully, because each one consumes what the previous one produced (image, container,
secret, stack).

### Build A — Phase 1 (development)

```
RUN_SONAR            = false
RUN_DEPENDENCY_CHECK = true      (see §8 if the NVD key is still rejected)
RUN_TRIVY_FS         = true
BUILD_IMAGE          = false
TRIVY_SCAN           = false
DEPLOY_CONTAINER     = false
ZAP_SCAN             = false
ACCEPTANCE_TESTS     = false
INFRA_TEST           = false
COMPLIANCE_CHECK     = false
PROD_DEPLOY          = false
SECURITY_SMOKE       = false
CONFIG_SAFETY        = false
MONITORING           = false
```

Stages: Checkout, Preflight, Build, Unit and security tests, Gitleaks,
Dependency-Check, Trivy fs, Dockerfile lint (hadolint).

### Build B — Phase 2 (acceptance)

```
RUN_SONAR            = false
RUN_DEPENDENCY_CHECK = true or false  (whatever Build A used)
RUN_TRIVY_FS         = true
BUILD_IMAGE          = true
TRIVY_SCAN           = true
DEPLOY_CONTAINER     = true
ZAP_SCAN             = true
ACCEPTANCE_TESTS     = true
INFRA_TEST           = true
COMPLIANCE_CHECK     = true
PROD_DEPLOY          = false
SECURITY_SMOKE       = false
CONFIG_SAFETY        = false
MONITORING           = false
```

Stages: everything above plus image build, image scan, container deploy, ZAP, acceptance,
infrastructure, compliance. Leave `PROD_DEPLOY` off so this build measures Phase 2 only.

### Build C — Phase 3 (production + security validation)

```
RUN_SONAR            = false
RUN_DEPENDENCY_CHECK = false
RUN_TRIVY_FS         = false
BUILD_IMAGE          = true      (or false if devsecops-demo:ci already exists)
TRIVY_SCAN           = false
DEPLOY_CONTAINER     = false
ZAP_SCAN             = false
ACCEPTANCE_TESTS     = false
INFRA_TEST           = false
COMPLIANCE_CHECK     = false
PROD_DEPLOY          = true
SECURITY_SMOKE       = true
CONFIG_SAFETY        = true
MONITORING           = false
```

Stages: Checkout, Preflight, Build, Unit tests, Gitleaks, image build,
`Deploy production container`, `Security smoke tests`, `Configuration safety check`.

`PROD_DEPLOY` is the only phase-3 switch that must be added; the other two default to
`true` and are listed here so the set is complete.

### Build D — Phase 4 (operations)

```
RUN_SONAR            = false
RUN_DEPENDENCY_CHECK = false
RUN_TRIVY_FS         = false
BUILD_IMAGE          = true
TRIVY_SCAN           = false
DEPLOY_CONTAINER     = true      <-- required, see note
ZAP_SCAN             = false
ACCEPTANCE_TESTS     = false
INFRA_TEST           = false
COMPLIANCE_CHECK     = false
PROD_DEPLOY          = false
SECURITY_SMOKE       = false
CONFIG_SAFETY        = false
MONITORING           = true
```

Note: Prometheus scrapes the target named `devsecops-app`, so the monitoring checks need
`DEPLOY_CONTAINER=true` — a production-only container (`PROD_DEPLOY`) is **not** scraped
and would show `up=0`.

The monitoring stack is left running after the build on purpose (it is what you show
during the defence). The application container is not: `post` removes it, so
`ApplicationDown` fires about a minute later. That is the alerting scenario, not a defect.

---

## 4. Expected console messages

### Phase 1

```
OK    jdk (tool jdk21)          openjdk version "21..."
OK    maven (tool maven)        Apache Maven ...
OK    gitleaks                  ...
OK    hadolint                  ...
OK    trivy                     ...
OK    python3                   Python 3...
OK    docker (daemon)           ...
OK    dependency-check CLI      ...
Tests run: 10, Failures: 0, Errors: 0, Skipped: 0
no leaks found
Checking NVD API key from Jenkins (32 chars)...
Jenkins credential HTTP 200
Dependency-Check report: reports/dependency-check-report.html
```

### Phase 2

```
built devsecops-demo:ci (sha256:...)
app ready after 12s on http://127.0.0.1:18080
PASS: 66, WARN: 2, FAIL: 0          (ZAP baseline; 2 warnings are expected)
Result: 11 passed, 0 failed          (acceptance)
Result: 9 passed, 0 failed           (compliance)
```

Infrastructure test prints `OK`/`FAIL` per VM property (`CPU cores`, `RAM`, `swap`,
`free disk`, `java`, `docker`, `trivy`, `gitleaks`, `hadolint`, `Dependency-Check CLI`,
port 8080).

### Phase 3

```
production container ready after 12s on port 18081
Security smoke test against http://127.0.0.1:18081
PASS  GET /hello answered: Hello from the DevSecOps course project!
PASS  header X-Content-Type-Options: nosniff
PASS  header X-Frame-Options: DENY
PASS  header Referrer-Policy: no-referrer
PASS  /actuator/health is exposed (HTTP 200)
PASS  /actuator/prometheus serves JVM metrics
PASS  /actuator discovery advertises only safe endpoints
PASS  /actuator/env stays closed (HTTP 404)
PASS  /actuator/beans stays closed (HTTP 404)
PASS  /actuator/heapdump stays closed (HTTP 404)
PASS  unknown route returns 404
PASS  HTTP TRACE refused (HTTP 405)
PASS  no X-Powered-By banner
Result: 13 passed, 0 failed
Configuration safety check (container: devsecops-prod)
PASS  container 'devsecops-prod' is running
PASS  container runs as uid 10001 (non-root)
PASS  image 'devsecops-demo:ci' is not :latest
PASS  container is not privileged
PASS  container is not using host networking (devsecops-net)
PASS  docker socket is not mounted into the container
PASS  APP_API_KEY is set at runtime (value not printed, 32 characters)
PASS  only expected ports listen on all interfaces: 22 8080 18080 18081 3000
Result: 8 passed, 0 failed
```

The key itself must never appear: the deploy stage disables xtrace (`set +x`) before
writing the 0600 env-file, so the console shows the file path, never the value.

### Phase 4

```
creating docker network devsecops-net
generated .../monitoring/.env with a random Grafana admin password
Prometheus is ready
Alertmanager is ready
Grafana is ready
Operations check
  prometheus  : http://127.0.0.1:9090
  grafana     : http://127.0.0.1:3000
  alertmanager: http://127.0.0.1:9093
  application : http://127.0.0.1:18080
PASS  Prometheus is ready
PASS  application target is UP (job=devsecops-app)
PASS  JVM metrics are being scraped (N series)
PASS  alert rules loaded: 6 (ApplicationDown,HighErrorRate,SlowResponses,HighHeapUsage,NodeDown,HostMemoryHigh)
PASS  alert rule present: ApplicationDown
PASS  alert rule present: HighErrorRate
PASS  alert rule present: SlowResponses
PASS  alert rule present: NodeDown
PASS  Grafana healthy (database=ok)
PASS  provisioned Grafana dashboard is present
PASS  only Grafana is published outside the VM; other ports are loopback
PASS  Alertmanager is ready
PASS  application exposes /actuator/prometheus
PASS  /actuator/env stays closed (HTTP 404)
INFO  alerts currently firing: ...
Result: 14 passed, 0 failed
```

---

## 5. Expected artifacts

| Phase | Artifact | Where |
|---|---|---|
| 1 | JUnit results | `target/surefire-reports/` (published by the JUnit step) |
| 1 | `reports/gitleaks-report.json` | archived |
| 1 | `reports/dependency-check-report.{html,xml}` | archived + HTML published |
| 1 | `reports/trivy-fs-report.txt`, `reports/trivy-fs-resolved-report.*`, `reports/sbom-cyclonedx.json` | archived |
| 1 | `reports/hadolint-report.txt` | archived |
| 2 | `reports/image-id.txt`, `reports/trivy-report.{txt,json}` | archived |
| 2 | `reports/zap-report.{html,json}` | archived + HTML published |
| 2 | `reports/acceptance-report.txt`, `reports/infra-report.txt`, `reports/compliance-report.txt` | archived |
| 3 | `reports/smoke-report.txt`, `reports/config-safety-report.txt` | archived |
| 4 | `reports/monitoring-report.txt` | archived |
| all | `post` archives `reports/**` even when a stage failed | build artifacts |

---

## 6. Inspecting what is running (read-only)

```bash
# containers and their published ports
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}\t{{.Status}}'

# production container details (no secret value is shown by these)
docker inspect devsecops-prod --format '{{.Config.User}} {{.HostConfig.NetworkMode}} {{.HostConfig.Privileged}}'
docker inspect devsecops-prod --format '{{range .Config.Env}}{{println .}}{{end}}' | sed 's/=.*/=<redacted>/'

# networks
docker network inspect devsecops-net --format '{{range .Containers}}{{.Name}} {{end}}'

# monitoring stack
docker compose -f monitoring/docker-compose.yml --env-file monitoring/.env ps
curl -s http://127.0.0.1:9090/-/ready
curl -s http://127.0.0.1:9093/-/ready
curl -s http://127.0.0.1:3000/api/health
curl -s 'http://127.0.0.1:9090/api/v1/targets' | python3 -m json.tool | grep -E 'job|health'

# ports on all interfaces (the check reads this same view)
ss -ltn | awk 'NR==1 || $4 ~ /^(0\.0\.0\.0|\*|\[::\]):/'
```

Grafana: `http://<vm-ip>:3000`, user `admin`, password in `monitoring/.env` (mode 0600,
gitignored). Prometheus and Alertmanager from the VM only, or through
`ssh -L 9090:127.0.0.1:9090 -L 9093:127.0.0.1:9093 vagrant@192.168.33.10`.

---

## 7. PASS, FAIL, BLOCKED, NOT TESTED

| Verdict | Meaning | Evidence required |
|---|---|---|
| **PASS** | The check ran and satisfied its assertion | The `PASS`/`OK` line, or the report file, from *this* build |
| **FAIL** | The check ran and the assertion was violated | The failing line plus the reason; never "fixed" by lowering a threshold |
| **BLOCKED** | The check could not run for an environmental reason (missing credential, absent service, unreachable host) | The `BLOCKED:`/`FAIL` line naming the missing prerequisite |
| **NOT TESTED** | The stage never ran (parameter off) or the result was never observed | State it explicitly; do not infer it from a green build |

A stage that is off is **NOT TESTED**, never PASS. A stage that was fixed afterwards is
**NOT TESTED** for the new revision until a build runs it.

The same four verdicts describe the project itself: **IMPLEMENTED** (code and configuration
exist), **STATICALLY VERIFIED** (the syntax/lint/parse gates), **RUNTIME-TESTED** (observed
in a Jenkins build with console or report evidence), **BLOCKED** (an environmental
prerequisite is missing). The per-phase table lives in
[release-checklist.md](release-checklist.md) §11 and in the README.

---

## 8. Known blocker — NVD API key rejected by Dependency-Check

**Symptom**

```
NvdApiException: NVD Returned Status Code: 403
org.owasp.dependencycheck.data.nvd.json.NvdApiRetryExceededException ... five times
Invalid API Key: 01234-*****-bcdef
```

or, in the diagnostic step, `Jenkins credential HTTP 403` / `HTTP 000`.

**What is already correct**

* The key is trimmed (`tr -d '[:space:]'`) and shape-checked (`8-4-4-4-12`) before use,
  so a trailing newline in the credential cannot produce a misleading 403.
* `set +x` runs before any expansion of the key: it never appears in the `sh -x` trace.
* The value is passed to the CLI through a `0600` property file removed by a `trap`.
* The gate (`--failOnCVSS 9`) and the report requirements are unchanged.

**How to resolve it later (manual, on the VM/Jenkins, not in this repository)**

1. Open <https://nvd.nist.gov/developers/request-an-api-key> and request a key for the
   email address you control; NVD mails it within a few minutes.
2. Jenkins → Manage Jenkins → Credentials → the `nvd-api-key` entry → **Update** →
   paste the new value. Remove any trailing space or newline.
3. Confirm it is a Secret text credential, not a username/password pair.
4. Re-run Build A (§3). Expected: `Jenkins credential HTTP 200`, then the scan downloads
   the NVD feed (first run is slow, later runs reuse `/opt/dependency-check/data`).
5. If NVD answers `403` with a fresh key, wait for the account to activate (new keys are
   rate-limited) and retry once; do not retry in a loop, and never "fix" it by removing
   `--failOnCVSS`.

**Until then:** run Phase 1 with `RUN_DEPENDENCY_CHECK=false`. That skips the NVD-backed
scan; it does **not** relax it. `RUN_TRIVY_FS=true` still scans the same dependency set,
without an API key, at the same CRITICAL gate. Record it as **BLOCKED**, not PASS, in the
report: never describe a skipped scan as a clean scan.

---

## 9. Cleanup

```bash
# stop the monitoring stack (it is meant to stay up between builds)
docker compose -f monitoring/docker-compose.yml --env-file monitoring/.env down

# remove the demo containers (the pipeline does this itself)
docker rm -f devsecops-app devsecops-prod

# remove the demo network (only when nothing is attached)
docker network rm devsecops-net

# keep the image and the Trivy/NVD caches: rebuilding them is the slow part
```

Do not delete `monitoring/.env`: it holds the generated Grafana password and is not in
git.

---

## 10. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `set: Illegal option -o pipefail` | A stage ran under `/bin/sh` (dash) | Already fixed: every `sh` block that uses `pipefail` starts with `#!/usr/bin/env bash`. If it reappears, the block lost its shebang |
| `Could not find credentials entry with ID 'app-api-key'` | Credential missing or misnamed | Create it as Secret text with that exact ID |
| `docker: permission denied … /var/run/docker.sock` | `jenkins` not in the `docker` group | `sudo bash scripts/install-phase2.sh`, then restart Jenkins |
| `Unable to find image 'devsecops-demo:ci' locally` | Phase 3 ran without the image | Tick `BUILD_IMAGE`, or run Build B first |
| `port is already allocated` on 18080/18081 | A stale container or a foreign process | `docker ps`, `sudo ss -ltnp \| grep 1808` |
| Smoke: `GET /hello returned nothing` | Nothing deployed | Tick `PROD_DEPLOY` or `DEPLOY_CONTAINER` |
| Config: `unexpected ports listening on all interfaces` | A service published something new | `sudo ss -ltnp`; fix the source, not the expected list |
| Config: `APP_API_KEY still holds the .env.example placeholder` | Credential value is `replace-me` | Set a real value in the credential |
| Deploy: `app-api-key contains a line break inside the value` | The credential was pasted as more than one line | Re-enter it as a single line; the stage strips a *trailing* CR/LF but refuses an embedded break, because `--env-file` cannot carry one |
| Deploy: `app-api-key is empty once line breaks are removed` | The credential holds only whitespace/line breaks | Re-enter the key; the stage refuses to start a container with no secret |
| Monitoring: `application target 'devsecops-app' does not exist` | No app container, or it was removed by a previous build | Re-run with `DEPLOY_CONTAINER=true` |
| Monitoring: compose validation fails | `monitoring/.env` missing or no password | `bash scripts/install-phase4.sh` regenerates it |
| Grafana 401 in the check | Password in `monitoring/.env` does not match the running container | `docker compose … down && bash scripts/install-phase4.sh` |
| Any stage red on CRITICAL/CVSS ≥ 9 | A real finding | Fix the dependency. Never lower `--failOnCVSS` or `--severity` |

---

## 11. Before you start — one-page checklist

Credentials, tools, images, ports, RAM/disk, the exact four-build order and the status
vocabulary are condensed into [release-checklist.md](release-checklist.md). Tick it before
the first build; every unticked line is a BLOCKED item for its phase.

---

## 12. What "done" looks like

* Build A: Phase 1 stages green, reports archived, Dependency-Check either green (key
  working) or **BLOCKED** and documented.
* Build B: 11/11 acceptance, 9/9 compliance, ZAP 0 FAIL, image scan 0 CRITICAL.
* Build C: 13/13 smoke, 8/8 configuration safety, secret never printed.
* Build D: 14/14 monitoring, Grafana dashboard visible, one alert demonstrably firing.
* Then, and only then: the numbers in `docs/rapport-final.md` and `docs/slides.md` can be
  filled in where they still say `[À REMPLIR: résultat réel du scan]`.
