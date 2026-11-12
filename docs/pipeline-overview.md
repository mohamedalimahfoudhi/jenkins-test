# Pipeline overview — the consolidated Jenkinsfile

One pipeline, four phases, one file: [`Jenkinsfile`](../Jenkinsfile) on branch
`devsecops-final`. It is the merge of the four phase branches, and it is the
pipeline to show and to quote in the report.

Everything here describes what the pipeline **does**, in which order, why that
order, and what fails the build. If a claim in the report cannot be traced to a
row in these tables, it should not be in the report.

Status vocabulary used across the documentation — **IMPLEMENTED** (code exists),
**STATICALLY VERIFIED** (syntax/lint/parse gates), **RUNTIME-TESTED** (observed in a
Jenkins build), **BLOCKED** (environmental prerequisite missing), **NOT TESTED** (never
ran) — with the per-phase table in [release-checklist.md](release-checklist.md).

---

## 1. Shape of the pipeline

```
Checkout
  └─ Preflight (tool checks)            fail fast if a scanner is missing
       └─ Build                          mvn clean compile
            └─ Unit and security tests   mvn test (10 tests)
                 ├─ Secrets scan (Gitleaks)                  history-wide
                 ├─ Dependency scan (OWASP Dependency-Check)  SCA, NVD feed
                 ├─ Dependency scan (Trivy fs)                SCA, no API key
                 ├─ Dockerfile lint (hadolint)                config as code
                 └─ Container image (build)  →  Container scan (Trivy)
                        └─ Deploy application container (18080)
                             ├─ DAST (OWASP ZAP baseline)
                             ├─ Security acceptance tests  (11 checks)
                             ├─ Infrastructure test (VM)
                             └─ Compliance check (policy)  (9 checks)
                                  └─ Deploy production container (18081)
                                       ├─ Security smoke tests        (13 checks)
                                       └─ Configuration safety check  (8 checks)
                                            └─ Operations: monitoring stack
                                                 └─ Operations: metrics and alerts check (14 checks)
                                                      └─ SAST (SonarQube)   [optional, last]
post { always: remove app containers, archive reports }
```

Twenty-one stages, fourteen parameters. The stage names are stable — the report,
the screenshots and the shell scripts refer to them by name.

---

## 2. Parameters

All fourteen are `booleanParam`. Defaults are chosen so that a plain build is safe
on a 4 GB VM: anything heavy, optional, or that needs a credential is **off**
unless you ask for it.

| Parameter | Default | Phase | Effect | Needs |
|---|---|---|---|---|
| `RUN_SONAR` | off | 1 | Runs `sonar:sonar` and waits for the quality gate | SonarQube server named `SonarQube`, ~2 GB free RAM |
| `RUN_DEPENDENCY_CHECK` | on | 1 | Runs the OWASP Dependency-Check stage (fails on CVSS ≥ 9.0) | Credential `nvd-api-key`, NVD data |
| `RUN_TRIVY_FS` | on | 1 | Runs the Trivy dependency scan: repository manifests + the dependency set Maven resolved (fails on CRITICAL) | `trivy`, `python3`, Maven |
| `BUILD_IMAGE` | on | 2 | Builds `devsecops-demo:ci` | Docker |
| `TRIVY_SCAN` | on | 2 | Scans the image, fails on CRITICAL | `trivy` on PATH |
| `DEPLOY_CONTAINER` | on | 2 | Runs the app container on 18080 | Docker |
| `ZAP_SCAN` | on | 2 | ZAP baseline DAST against the container | ~1 GB RAM for the ZAP container |
| `ACCEPTANCE_TESTS` | on | 2 | Runs `security-acceptance-test.sh` (11 checks) | A deployed app on 18080 |
| `INFRA_TEST` | on | 2 | Runs `infra-check.sh` (VM state) | — |
| `COMPLIANCE_CHECK` | on | 2 | Runs `compliance-check.sh` (9 checks) | `Dockerfile`, `Jenkinsfile` |
| `PROD_DEPLOY` | **off** | 3 | Deploys the production container on 18081 with the secret injected | Credential `app-api-key` |
| `SECURITY_SMOKE` | on | 3 | Runs `security-smoke-test.sh` (13 checks) | A deployed app (18081 or 18080) |
| `CONFIG_SAFETY` | on | 3 | Runs `config-safety-check.sh` (8 checks) | The production container |
| `MONITORING` | **off** | 4 | Starts the monitoring stack and runs `monitoring-check.sh` (14 checks) | ~1 GB RAM, Docker, `devsecops-net` |

Dependency order between parameters (what actually happens if you tick one
without the other):

* `TRIVY_SCAN` without `BUILD_IMAGE` → scans nothing (the image is missing) and fails.
* `ZAP_SCAN`, `ACCEPTANCE_TESTS` without `DEPLOY_CONTAINER` → no target, they fail.
* `RUN_DEPENDENCY_CHECK` off → the NVD-backed scan is *skipped, never relaxed*; the
  Trivy dependency scan still covers the same dependencies with no API key. Both
  gates stay at CRITICAL/CVSS ≥ 9.0 whenever they run.
* `SECURITY_SMOKE`/`CONFIG_SAFETY` without `PROD_DEPLOY` → both fall back to the
  acceptance container on 18080; the configuration check then reports the
  runtime-secret assertion as *information* instead of a pass, because only the
  production container is supposed to carry that secret. With no container at
  all, it fails closed.
* `MONITORING` works on its own: `install-phase4.sh` creates the network if the
  application has not done it yet, but the `devsecops-app` scrape target only
  exists when `DEPLOY_CONTAINER` ran in the same build.

---

## 3. Stages

"Gate" is what turns the stage red. Reports are archived even when the stage
fails, which is the point: a failed build must still leave evidence.

| # | Stage | Phase | What it proves | Gate (fails when) | Artifact |
|---|---|---|---|---|---|
| 1 | `Checkout` | 1 | The build runs on the right commit | SCM error | — |
| 2 | `Preflight (tool checks)` | 1 | `java`, `mvn`, `gitleaks`, `hadolint`, `trivy`, `python3` are usable | Any tool missing | — |
| 3 | `Build` | 1 | The code compiles | Compile error | — |
| 4 | `Unit and security tests` | 1 | Behaviour and security rules hold (10 tests) | Any test fails | `target/surefire-reports/*.xml` (JUnit view) |
| 5 | `Secrets scan (Gitleaks)` | 1 | No secret in the whole git history | Any finding | `reports/gitleaks-report.json` |
| 6 | `Dependency scan (OWASP Dependency-Check)` | 1 | Third-party libraries have no known critical CVE, from the NVD feed. Runs the CLI from `scripts/install-dependency-check.sh`, not the plugin's tool registration | Any CVSS ≥ 9.0 (`--failOnCVSS 9`), or no dependency jar resolved | `reports/dependency-check-report.xml/html` |
| 7 | `Dependency scan (Trivy fs)` | 1 | No resolved dependency matches a CRITICAL CVE in Trivy's database — no API key, no Docker | Any CRITICAL, or a scan that matched nothing | `reports/trivy-fs-report.*`, `reports/trivy-fs-resolved-report.*`, `reports/dependencies.txt`, `reports/sbom-cyclonedx.json` |
| 8 | `Dockerfile lint (hadolint)` | 1 | The Dockerfile follows the rules (pinned base, non-root, no `latest`) | Any lint finding | `reports/hadolint-report.txt` |
| 9 | `Container image (build)` | 2 | The image builds reproducibly | `docker build` fails | `reports/image-id.txt` |
| 10 | `Container scan (Trivy)` | 2 | The shipped image has no known critical CVE | Any CRITICAL | `reports/trivy-report.txt/.json` |
| 11 | `Deploy application container` | 2 | The image actually starts and answers | Not ready within 40 s | container logs in the console |
| 12 | `DAST (OWASP ZAP baseline)` | 2 | No baseline web finding against the running service | A ZAP `FAIL` rule (warnings do not fail, `-I`) | `reports/zap-report.html/.json` |
| 13 | `Security acceptance tests` | 2 | The API's security contract (status codes, headers, error handling) | Any of 11 checks fails | `reports/acceptance-report.txt` |
| 14 | `Infrastructure test (VM)` | 2 | The host is in the expected state (swap, docker, firewall, tools) | Any hard failure | `reports/infra-report.txt` |
| 15 | `Compliance check (policy)` | 2 | Dockerfile/Jenkinsfile obey the written policy | Any of 9 checks fails | `reports/compliance-report.txt` |
| 16 | `Deploy production container` | 3 | The service starts with a runtime secret injected | Not ready within 40 s | container logs |
| 17 | `Security smoke tests` | 3 | Post-deploy security promises hold (13 checks) | Any check fails | `reports/smoke-report.txt` |
| 18 | `Configuration safety check` | 3 | Runtime config is safe (ports, non-root, secret handling) | Any of 8 checks fails | `reports/config-safety-report.txt` |
| 19 | `Operations: monitoring stack` | 4 | Prometheus/Alertmanager/Grafana/node_exporter start | Compose or readiness fails | — |
| 20 | `Operations: metrics and alerts check` | 4 | Metrics flow, rules load, dashboard exists, exposure is loopback-only | Any of 14 checks fails | `reports/monitoring-report.txt` |
| 21 | `SAST (SonarQube)` | 1 (SAST) | Static analysis and quality gate | Gate not OK | SonarQube UI |

### Why this order

* **Preflight first.** Without it, a missing binary surfaces as a confusing
  failure inside a security stage. With it, the build says exactly what to
  install.
* **Scans before the image build.** A secret or a bad dependency costs nothing
  to find on the source; finding it after the image exists wastes minutes on a
  slow link.
* **Deploy before DAST and acceptance.** Both need a live service. ZAP is told
  the container's name on the Docker network, not the host port.
* **Smoke after the production deploy.** The smoke test is the promotion gate:
  it checks the *deployed* instance, not the source.
* **SonarQube last.** SonarQube server plus scanner is the biggest memory
  consumer (≈ 2 GB with its PostgreSQL). Running it last means it never
  overlaps ZAP or a monitoring stack.

Memory budget on the 4 GB VM, at the moment the heaviest stages run:

| Consumer | Rough usage |
|---|---|
| Jenkins itself | ~1 GB |
| Application container | ~300 MB |
| ZAP container | ~1 GB |
| SonarQube + PostgreSQL (only with `RUN_SONAR`) | ~2 GB |
| Monitoring stack (only with `MONITORING`) | ~960 MB (limits) |

Tick `ZAP_SCAN` and `RUN_SONAR` in the same build and the box will swap; that is
a documented trade-off, not a bug. For the defence, go to 8 GB.

---

## 4. Artifacts

Every report is written under `reports/` (or `dependency-check-report.*` for the
plugin) and archived by `post { always { archiveArtifacts 'reports/**' } }`, so a
failed build still leaves its evidence:

| File | Stage |
|---|---|
| `target/surefire-reports/*.xml` | Unit and security tests (also published in the JUnit view) |
| `reports/gitleaks-report.json` | Secrets scan |
| `reports/dependency-check-report.html` / `.xml` | Dependency scan (HTML published in the job page) |
| `reports/trivy-fs-report.txt` / `.json` | Dependency scan (Trivy fs) — repository manifests |
| `reports/dependencies.txt`, `reports/sbom-cyclonedx.json` | Dependency scan (Trivy fs) — the dependency set Maven resolved, as a CycloneDX SBOM |
| `reports/trivy-fs-resolved-report.txt` / `.json` | Dependency scan (Trivy fs) — the scan of that SBOM |
| `reports/hadolint-report.txt` | Dockerfile lint |
| `reports/image-id.txt` | Container image (build) — the exact image under test |
| `reports/trivy-report.txt` / `.json` | Container scan |
| `reports/zap-report.html` / `.json` | DAST (HTML published in the job page) |
| `reports/acceptance-report.txt` | Security acceptance tests |
| `reports/infra-report.txt` | Infrastructure test |
| `reports/compliance-report.txt` | Compliance check |
| `reports/smoke-report.txt` | Security smoke tests |
| `reports/config-safety-report.txt` | Configuration safety check |
| `reports/monitoring-report.txt` | Operations: metrics and alerts check |

---

## 5. Cleanup semantics

`post { always { ... } }` removes `devsecops-app` and `devsecops-prod` on every
build, success or failure, so the next build can never test a stale container.

The Docker network `devsecops-net` is removed **only when nothing is attached to
it**. If the monitoring stack is running (it is started deliberately and stays
up for the demo), the network is kept — otherwise Prometheus would lose the
target it scrapes by container name, and `docker network rm` would fail anyway.

Consequences worth knowing, and worth one line in the report:

* The application containers are gone after the build, so Grafana shows the
  application panels dropping to zero and `ApplicationDown` starts firing about
  a minute later. That is the honest way to demonstrate alerting.
* The monitoring stack is **not** torn down by the pipeline. Stop it with
  `docker compose -f monitoring/docker-compose.yml down`.

---

## 6. Running it

First build, with the defaults (safe on 4 GB):

1. Jenkins → the job → **Build with Parameters** → leave defaults → **Build**.
2. Expect every stage except `Deploy production container`, the operations
   stages and `SAST (SonarQube)` to run (they are off by default).
3. On a slow link the first build is dominated by the NVD download
   (Dependency-Check) and the Trivy database (≈ 133 MB); later builds reuse both.
4. If the NVD key is rejected (`Invalid apiKey`), untick
   `RUN_DEPENDENCY_CHECK` rather than deleting the stage: the Trivy dependency
   scan covers the same dependencies without any key.

Full demonstration build:

* tick `PROD_DEPLOY`, `MONITORING` (and optionally `RUN_SONAR` if the VM has 8 GB
  and a SonarQube server is configured).

Individual scripts can also be run by hand on the VM; each one documents its
`BASE_URL`/`CONTAINER`/`MONITORING_ENV_FILE` overrides at the top of the file.

For a phase-by-phase validation session (exact parameter sets, expected console lines,
artifacts, verdicts), use [final-validation-guide.md](final-validation-guide.md).

---

## 7. Failure playbook

| Symptom | Cause | Fix |
|---|---|---|
| `Preflight` red: `gitleaks: command not found` | Tools installed under a different user | `sudo bash scripts/install-tools.sh`; tools land in `/usr/local/bin` |
| `Preflight` red: `mvn -v` fails | Tool names differ in this Jenkins | Global Tool Configuration: JDK `jdk21`, Maven `maven` |
| `Dependency scan` red: `ERROR: Couldn't find any executable in "null"` | the **plugin's** tool registration was empty — this is what happened on the first VM build | the stage no longer uses the plugin: rebuild with the current `Jenkinsfile`. If it instead prints `Dependency-Check CLI not found at /opt/dependency-check/...`, run `sudo bash scripts/install-dependency-check.sh` |
| `Dependency scan` fails at start | NVD API key missing or invalid (`Invalid apiKey`) | Fix or regenerate the key at nvd.nist.gov, or untick `RUN_DEPENDENCY_CHECK`: the Trivy dependency scan still runs, so the build is not left unscanned |
| `Dependency scan` red: `no dependency jar in target/deps` | `mvn dependency:copy-dependencies` produced nothing | Read the Maven error above it (usually the `jenkins` user cannot write `~/.m2`) |
| `Dependency scan` times out | NVD rate limit on a slow link | Run it once more; the local NVD cache is reused |
| `Dependency scan (Trivy fs)` red: `refusing to write an empty SBOM` | `mvn dependency:list` produced nothing — usually a local repository the `jenkins` user cannot write | Read the Maven error printed just above it, then fix ownership of `~jenkins/.m2` |
| `Dependency scan (Trivy fs)` red on CRITICAL | A dependency that actually ships has a known critical CVE | That is the gate working: fix the dependency (the fix in this project was raising Spring Boot), never the threshold. Details in `reports/trivy-fs-resolved-report.txt` |
| `Container image` fails: `permission denied /var/run/docker.sock` | `jenkins` not in the `docker` group | `sudo bash scripts/install-phase2.sh`, then log out/in for Jenkins |
| `Deploy application container`: not ready in 40 s | Image starts but the app crashes | Read `docker logs devsecops-app` printed by the stage |
| `Deploy application container`: port already allocated | A previous container still holds 18080 | `docker rm -f devsecops-app` (the pipeline does this itself, so this means something else owns the port) |
| `DAST` fails immediately | ZAP image not pulled yet, or `reports/` not writable by the ZAP user | `docker pull zaproxy/zap-stable:2.17.0`; the stage already does `chmod a+w reports` |
| `Deploy production container` waits | Credential `app-api-key` missing → `withCredentials` fails first | Create the credential |
| `Operations: monitoring stack` fails on compose validation | `monitoring/.env` missing or has no `GRAFANA_ADMIN_PASSWORD` | `sudo bash scripts/install-phase4.sh` regenerates it (0600) |
| `Operations: metrics and alerts check`: target `up=0` | The app container is gone (a previous build removed it) | Re-run with `DEPLOY_CONTAINER` ticked |
| `Configuration safety check`: unexpected port | Something new listens on all interfaces | `sudo ss -ltnp`; fix the source rather than the expected-port list |

---

## 8. First run on the VM — the most likely failure per stage

Jenkins build #11 ran the Phase 1 and Phase 2 stages on the VM (image built, image scan
0 CRITICAL, container deployed, ZAP 66 PASS / 0 FAIL / 2 WARN, acceptance 11/11).
Phase 3 and Phase 4 have not executed yet, so the rows for those stages are still
predictions rather than observations. Environment: Ubuntu 22.04, 4 GB of RAM, Jenkins
running as the `jenkins` user. Each row has a one-line fix.

| Stage | Most likely failure | One-line fix |
|---|---|---|
| `Container image (build)` | `permission denied while trying to connect to the Docker daemon socket` — `jenkins` is not in the `docker` group | `sudo usermod -aG docker jenkins && sudo systemctl restart jenkins` |
| `Container scan (Trivy)` | `devsecops-demo:ci not found` (image not built), or no disk left for the Trivy DB in `~jenkins/.cache/trivy` | Keep `BUILD_IMAGE` ticked; `df -h /` and `sudo du -sh /var/lib/docker` before the demo |
| `Deploy application container` | `port is already allocated` — a container from an aborted build still holds 18080 | `docker rm -f devsecops-app` (the pipeline clears its own, so something else owns the port) |
| `DAST (OWASP ZAP baseline)` | the 1 GB ZAP image is not pulled yet, or the box swaps on 4 GB | `docker pull zaproxy/zap-stable:2.17.0`, then run ZAP with `RUN_SONAR` off |
| `Security acceptance tests` | `curl: (7) Failed to connect` — nothing is listening on 18080 | Keep `DEPLOY_CONTAINER` ticked and read `docker logs devsecops-app` |
| `Infrastructure test (VM)` | no swap on a 4 GB VM, or ufw/fail2ban absent | `sudo bash scripts/add-swap.sh`; `sudo bash scripts/install-phase3.sh` |
| `Compliance check (policy)` | `Jenkinsfile not found` — the job checked out a branch without it | Point the job at `devsecops-final` |
| `Deploy production container` | `Could not find credentials entry with ID 'app-api-key'` | Create the secret-text credential with that exact ID |
| `Security smoke tests` | no container on 18081 or 18080 | Tick `PROD_DEPLOY` (or `DEPLOY_CONTAINER`) |
| `Configuration safety check` | an unexpected port is listening on all interfaces | `sudo ss -ltnp`; fix the source. 9090/9093/9100 are loopback-only by design, only 3000 and 8080/18080/18081 should be published |
| `Operations: monitoring stack` | `monitoring/.env` missing, or no `GRAFANA_ADMIN_PASSWORD` in it | `sudo bash scripts/install-phase4.sh` (regenerates it, mode 0600) |
| `Operations: metrics and alerts check` | `up{job="devsecops-app"} == 0` because the application container was removed at the end of a previous build | Re-run with `DEPLOY_CONTAINER` ticked, or accept 13/14 and explain the alerting scenario |
| `SAST (SonarQube)` | no server named `SonarQube` under Manage Jenkins > System | Leave `RUN_SONAR` off (it is off by default and declared optional) |

## 9. Non-goals

Stated so nobody mistakes absence for an oversight:

* **No CD to a real environment.** "Production" is a second container on the same
  VM, with a secret injected at runtime. There is no remote host, no registry
  push, no blue/green.
* **No image registry.** The image lives only in the VM's Docker daemon.
* **No secrets manager.** Two Jenkins credentials; Docker secrets would need
  Swarm, and on one host the Docker socket is already root-equivalent.
* **No TLS.** Jenkins and the app speak plain HTTP on a host-only Vagrant
  network; TLS termination is out of scope for this project.
* **No paging.** Alertmanager has a documented silent default receiver: real
  rules, no on-call system.

---

## 10. Where the phase evidence lives

| Phase | Branch | Proof |
|---|---|---|
| 1 Development | `devsecops-phase1` | `docs/threat-model.md`, `docs/development-setup.md`, `.githooks/pre-commit` |
| 2 Acceptance | `devsecops-phase2` | `scripts/install-phase2.sh`, `security-acceptance-test.sh` (11), `infra-check.sh`, `compliance-check.sh` (9) |
| 3 Production | `devsecops-phase3` | `scripts/install-phase3.sh`, `security-smoke-test.sh` (13), `config-safety-check.sh` (8) |
| 4 Operations | `devsecops-phase4` | `monitoring/**`, `scripts/install-phase4.sh`, `scripts/monitoring-check.sh` (14) |
| Final | `devsecops-final` | this document, `docs/tools-table.md`, consolidated `Jenkinsfile` |
