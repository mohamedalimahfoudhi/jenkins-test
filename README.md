# jenkins-test — DevSecOps pipeline (phases 1 to 4)

A small Spring Boot service and the Jenkins pipeline that builds, scans, deploys and
monitors it. The point of the project is the pipeline, not the application: every stage
either produces evidence or fails the build.

## What runs

| Phase | Stages |
|---|---|
| 1 — Development | Build, unit + security tests, Gitleaks, OWASP Dependency-Check, Trivy fs, hadolint, optional SonarQube |
| 2 — Acceptance | Docker image build, Trivy image scan, container deploy (18080), OWASP ZAP baseline, security acceptance tests, infrastructure test, compliance check |
| 3 — Production | Production container with a Jenkins-injected secret (18081), security smoke tests, configuration safety check |
| 4 — Operations | Prometheus, Alertmanager, Grafana, node_exporter, and a 14-check operations verification |

21 stages, 14 parameters. Every heavy or risky stage is a switch, and the defaults are
chosen so a plain build is safe on a 4 GB VM.

## Architecture

One VM, one Jenkins job, no external service. Everything the pipeline touches is local:

```
Ubuntu 22.04 VM (4 GB)
│
├─ Jenkins :8080                     job devsecops-pipeline, Pipeline from SCM
│    └─ workspace ── mvn ── target/  (jar + surefire reports)
│
├─ Docker daemon
│    ├─ devsecops-demo:ci            image built by the pipeline
│    ├─ devsecops-app   :18080→8080  acceptance container   (Phase 2)
│    ├─ devsecops-prod  :18081→8080  production container    (Phase 3, secret injected)
│    └─ devsecops-net                shared bridge network for all of the above
│
├─ monitoring stack (Phase 4, compose project devsecops-monitoring)
│    ├─ prometheus   127.0.0.1:9090  scrapes devsecops-app:8080 and node-exporter:9100
│    ├─ alertmanager 127.0.0.1:9093  receives the 6 alert rules
│    ├─ grafana      0.0.0.0:3000    provisioned dashboard "DevSecOps - Application and host"
│    └─ node-exporter 127.0.0.1:9100 host metrics (read-only /, pid: host)
│
└─ /opt/dependency-check            Dependency-Check CLI + its NVD data cache
```

No image is pushed anywhere, no remote host is contacted, and the only inbound ports are
SSH, Jenkins and (optionally) Grafana. `devsecops-prod` is a **second local container**,
not a remote environment.

## Pipeline flow

```
Checkout → Preflight → Build → Unit and security tests
   ├─ Gitleaks                    (history-wide secret scan)
   ├─ Dependency-Check            (NVD feed, gate CVSS ≥ 9)
   ├─ Trivy fs                    (resolved deps via SBOM, gate CRITICAL)
   ├─ hadolint                    (Dockerfile lint)
   └─ image build → image scan → deploy 18080 → ZAP → acceptance (11)
                                        → infra → compliance (9)
                                             └─ deploy 18081 (secret) → smoke (13) → config safety (8)
                                                  └─ monitoring stack → metrics/alerts check (14)
                                                       └─ SonarQube [optional, last]
post { always: remove app containers, keep the network if monitoring is attached, archive reports/** }
```

Stage-by-stage detail, guards and cleanup semantics:
[`docs/pipeline-overview.md`](docs/pipeline-overview.md).

## Quick start

1. Jenkins: JDK tool `jdk21`, Maven tool `maven`, and two **Secret text** credentials
   with IDs `nvd-api-key` and `app-api-key`.
2. VM: `sudo bash scripts/install-tools.sh`, `sudo bash scripts/install-phase2.sh`
   (Docker for the `jenkins` user), `sudo bash scripts/install-dependency-check.sh`,
   `sudo bash scripts/add-swap.sh`.
3. Job: Pipeline from SCM, this repository, script path `Jenkinsfile`.
4. Build with Parameters — use the exact per-phase parameter sets in
   [`docs/final-validation-guide.md`](docs/final-validation-guide.md).

## Where things are

| File | Contents |
|---|---|
| [`Jenkinsfile`](Jenkinsfile) | The whole pipeline |
| [`docs/final-validation-guide.md`](docs/final-validation-guide.md) | **Manual validation: prerequisites, parameter sets, expected output, troubleshooting** |
| [`docs/release-checklist.md`](docs/release-checklist.md) | Release readiness: credentials, tools, images, ports, resources, test order |
| [`docs/pipeline-overview.md`](docs/pipeline-overview.md) | Stage-by-stage reference, cleanup semantics, failure playbook |
| [`docs/verification-here.md`](docs/verification-here.md) | What was executed outside the VM, with results |
| [`docs/rapport-final.md`](docs/rapport-final.md) | French final report |
| [`docs/tools-table.md`](docs/tools-table.md) | Tool inventory and pinned versions |
| `scripts/` | Every check the pipeline runs, runnable standalone |
| `monitoring/` | Prometheus, Alertmanager, Grafana, node_exporter configuration |

## Status, honestly

Four verdicts only, never blurred: **IMPLEMENTED** (code exists), **STATICALLY VERIFIED**
(the syntax/lint/parse gates in the release checklist), **RUNTIME-TESTED** (observed in a
Jenkins build on the VM), **BLOCKED** (environmental), **NOT TESTED** (never ran).

| Phase | IMPLEMENTED | STATICALLY VERIFIED | RUNTIME-TESTED |
|---|---|---|---|
| 1 — Development | yes | yes | partly: build, 10 tests, Gitleaks, Trivy fs in build #11; Dependency-Check **BLOCKED** (NVD key rejected) |
| 2 — Acceptance | yes | yes | yes, build #11: image built, image scan 0 CRITICAL, ZAP 66 PASS / 0 FAIL / 2 WARN, acceptance 11/11 |
| 3 — Production | yes | yes | **NOT TESTED** |
| 4 — Operations | yes | yes | **NOT TESTED** |

The NVD API key is currently rejected by NVD (`Invalid API Key`). Dependency-Check is
**not** removed and its CVSS ≥ 9 gate is unchanged; until the key is replaced the stage is
skipped with `RUN_DEPENDENCY_CHECK=false` and Trivy fs still scans the same dependencies.
Report it as BLOCKED, never as a clean scan. Resolution steps: validation guide §8.

## Safety

"Production" is a second container on the same VM, never a real remote environment. No
secret is committed: both credentials come from Jenkins at run time, and monitoring's
Grafana password is generated into a gitignored `0600` file. Monitoring publishes only
Grafana (3000); Prometheus, Alertmanager and node_exporter stay on `127.0.0.1`.
