# Pipeline overview — the consolidated Jenkinsfile

One pipeline, four phases, one file: [`Jenkinsfile`](../Jenkinsfile) on branch
`devsecops-final`. It is the merge of the four phase branches, and it is the
pipeline to show and to quote in the report.

Everything here describes what the pipeline **does**, in which order, why that
order, and what fails the build. If a claim in the report cannot be traced to a
row in these tables, it should not be in the report.

---

## 1. Shape of the pipeline

```
Checkout
  └─ Preflight (tool checks)            fail fast if a scanner is missing
       └─ Build                          mvn clean compile
            └─ Unit and security tests   mvn test (10 tests)
                 ├─ Secrets scan (Gitleaks)                  history-wide
                 ├─ Dependency scan (OWASP Dependency-Check)  SCA
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

Twenty stages, twelve parameters. The stage names are stable — the report, the
screenshots and the shell scripts refer to them by name.

---

## 2. Parameters

All twelve are `booleanParam`. Defaults are chosen so that a plain build is safe
on a 4 GB VM: anything heavy, optional, or that needs a credential is **off**
unless you ask for it.

| Parameter | Default | Phase | Effect | Needs |
|---|---|---|---|---|
| `RUN_SONAR` | off | 1 | Runs `sonar:sonar` and waits for the quality gate | SonarQube server named `SonarQube`, ~2 GB free RAM |
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
* `SECURITY_SMOKE`/`CONFIG_SAFETY` without `PROD_DEPLOY` → smoke falls back to the
  acceptance container on 18080; the configuration check needs the production
  container and will report it missing.
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
| 2 | `Preflight (tool checks)` | 1 | `java`, `mvn`, `gitleaks`, `hadolint` are usable | Any tool missing | — |
| 3 | `Build` | 1 | The code compiles | Compile error | — |
| 4 | `Unit and security tests` | 1 | Behaviour and security rules hold (10 tests) | Any test fails | `target/surefire-reports/*.xml` (JUnit view) |
| 5 | `Secrets scan (Gitleaks)` | 1 | No secret in the whole git history | Any finding | `reports/gitleaks-report.json` |
| 6 | `Dependency scan (OWASP Dependency-Check)` | 1 | Third-party libraries have no known critical CVE | Any CVSS ≥ 9.0 | `dependency-check-report.xml/html` |
| 7 | `Dockerfile lint (hadolint)` | 1 | The Dockerfile follows the rules (pinned base, non-root, no `latest`) | Any lint finding | `reports/hadolint-report.txt` |
| 8 | `Container image (build)` | 2 | The image builds reproducibly | `docker build` fails | `reports/image-id.txt` |
| 9 | `Container scan (Trivy)` | 2 | The shipped image has no known critical CVE | Any CRITICAL | `reports/trivy-report.txt/.json` |
| 10 | `Deploy application container` | 2 | The image actually starts and answers | Not ready within 40 s | container logs in the console |
| 11 | `DAST (OWASP ZAP baseline)` | 2 | No baseline web finding against the running service | A ZAP `FAIL` rule (warnings do not fail, `-I`) | `reports/zap-report.html/.json` |
| 12 | `Security acceptance tests` | 2 | The API's security contract (status codes, headers, error handling) | Any of 11 checks fails | `reports/acceptance-report.txt` |
| 13 | `Infrastructure test (VM)` | 2 | The host is in the expected state (swap, docker, firewall, tools) | Any hard failure | `reports/infra-report.txt` |
| 14 | `Compliance check (policy)` | 2 | Dockerfile/Jenkinsfile obey the written policy | Any of 9 checks fails | `reports/compliance-report.txt` |
| 15 | `Deploy production container` | 3 | The service starts with a runtime secret injected | Not ready within 40 s | container logs |
| 16 | `Security smoke tests` | 3 | Post-deploy security promises hold (13 checks) | Any check fails | `reports/smoke-report.txt` |
| 17 | `Configuration safety check` | 3 | Runtime config is safe (ports, non-root, secret handling) | Any of 8 checks fails | `reports/config-safety-report.txt` |
| 18 | `Operations: monitoring stack` | 4 | Prometheus/Alertmanager/Grafana/node_exporter start | Compose or readiness fails | — |
| 19 | `Operations: metrics and alerts check` | 4 | Metrics flow, rules load, dashboard exists, exposure is loopback-only | Any of 14 checks fails | `reports/monitoring-report.txt` |
| 20 | `SAST (SonarQube)` | 1 (SAST) | Static analysis and quality gate | Gate not OK | SonarQube UI |

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
| `dependency-check-report.html` / `.xml` | Dependency scan (HTML published in the job page) |
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
   (Dependency-Check) and the Trivy database; later builds reuse both.

Full demonstration build:

* tick `PROD_DEPLOY`, `MONITORING` (and optionally `RUN_SONAR` if the VM has 8 GB
  and a SonarQube server is configured).

Individual scripts can also be run by hand on the VM; each one documents its
`BASE_URL`/`CONTAINER`/`MONITORING_ENV_FILE` overrides at the top of the file.

---

## 7. Failure playbook

| Symptom | Cause | Fix |
|---|---|---|
| `Preflight` red: `gitleaks: command not found` | Tools installed under a different user | `sudo bash scripts/install-tools.sh`; tools land in `/usr/local/bin` |
| `Preflight` red: `mvn -v` fails | Tool names differ in this Jenkins | Global Tool Configuration: JDK `jdk21`, Maven `maven` |
| `Dependency scan` fails at start | NVD API key missing or invalid | Credential `nvd-api-key` (secret text) under Manage Jenkins > Credentials |
| `Dependency scan` times out | NVD rate limit on a slow link | Run it once more; the local NVD cache is reused |
| `Container image` fails: `permission denied /var/run/docker.sock` | `jenkins` not in the `docker` group | `sudo bash scripts/install-phase2.sh`, then log out/in for Jenkins |
| `Deploy application container`: not ready in 40 s | Image starts but the app crashes | Read `docker logs devsecops-app` printed by the stage |
| `Deploy application container`: port already allocated | A previous container still holds 18080 | `docker rm -f devsecops-app` (the pipeline does this itself, so this means something else owns the port) |
| `DAST` fails immediately | ZAP image not pulled yet, or `reports/` not writable by the ZAP user | `docker pull zaproxy/zap-stable:2.17.0`; the stage already does `chmod a+w reports` |
| `Deploy production container` waits | Credential `app-api-key` missing → `withCredentials` fails first | Create the credential |
| `Operations: monitoring stack` fails on compose validation | `monitoring/.env` missing or has no `GRAFANA_ADMIN_PASSWORD` | `sudo bash scripts/install-phase4.sh` regenerates it (0600) |
| `Operations: metrics and alerts check`: target `up=0` | The app container is gone (a previous build removed it) | Re-run with `DEPLOY_CONTAINER` ticked |
| `Configuration safety check`: unexpected port | Something new listens on all interfaces | `sudo ss -ltnp`; fix the source rather than the expected-port list |

---

## 8. Non-goals

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

## 9. Where the phase evidence lives

| Phase | Branch | Proof |
|---|---|---|
| 1 Development | `devsecops-phase1` | `docs/threat-model.md`, `docs/development-setup.md`, `.githooks/pre-commit` |
| 2 Acceptance | `devsecops-phase2` | `scripts/install-phase2.sh`, `security-acceptance-test.sh` (11), `infra-check.sh`, `compliance-check.sh` (9) |
| 3 Production | `devsecops-phase3` | `scripts/install-phase3.sh`, `security-smoke-test.sh` (13), `config-safety-check.sh` (8) |
| 4 Operations | `devsecops-phase4` | `monitoring/**`, `scripts/install-phase4.sh`, `scripts/monitoring-check.sh` (14) |
| Final | `devsecops-final` | this document, `docs/tools-table.md`, consolidated `Jenkinsfile` |
