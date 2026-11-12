# Release checklist — one page before the manual validation session

Tick every box that must be true **before** the first build of the session. Anything
unticked is a BLOCKED item for that phase, not something to discover mid-demo.

Companion documents: [final-validation-guide.md](final-validation-guide.md) (how to run each
phase), [pipeline-overview.md](pipeline-overview.md) (what every stage does).

---

## 1. Required Jenkins credentials

| Checkbox | Item | Exact value |
|---|---|---|
| ☐ | NVD key, kind **Secret text**, ID `nvd-api-key` | a key from <https://nvd.nist.gov/developers/request-an-api-key>; no trailing space or newline |
| ☐ | Runtime app secret, kind **Secret text**, ID `app-api-key` | any non-placeholder value (not `replace-me`) |

Credentials are read only through `withCredentials`; neither value may appear in the
repository, in a parameter, or in a shell argument.

## 2. Required Jenkins configuration

| Checkbox | Item | Exact value |
|---|---|---|
| ☐ | JDK tool | name `jdk21` (Java 17+ required, 21 used) |
| ☐ | Maven tool | name `maven` |
| ☐ | Plugins | Pipeline, Git, Credentials Binding, JUnit, HTML Publisher, Timestamper |
| ☐ | Optional | SonarQube server named `SonarQube` — only if `RUN_SONAR=true` |
| ☐ | Job | Pipeline from SCM, this repository, script path `Jenkinsfile` |
| ☐ | Job branch | `*/nvd-credential-diagnostic` (or `*/devsecops-final`) |
| ☐ | Job no-shallow-clone | Gitleaks scans history, so the clone must not be shallow |

## 3. Required VM software and services

| Checkbox | Item | Installer / check |
|---|---|---|
| ☐ | Ubuntu 22.04, ≥ 2 CPU, ≥ 4 GB RAM | `infra-check.sh` asserts it |
| ☐ | Swap configured | `sudo bash scripts/add-swap.sh` |
| ☐ | Docker + compose v2, `jenkins` in `docker` group | `sudo bash scripts/install-phase2.sh`, then restart Jenkins |
| ☐ | `gitleaks`, `hadolint`, `trivy`, `python3`, `curl`, `ss` | `sudo bash scripts/install-tools.sh`; `curl` via `apt-get install -y curl` |
| ☐ | Dependency-Check CLI at `/opt/dependency-check` | `sudo bash scripts/install-dependency-check.sh` |
| ☐ | Jenkins reachable on `127.0.0.1:8080` | `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/api/json` |

## 4. Required Docker images (pinned — no `:latest`)

| Checkbox | Image | Purpose |
|---|---|---|
| ☐ | `devsecops-demo:ci` | built by the pipeline (`BUILD_IMAGE`); the only image Phase 3 deploys |
| ☐ | `maven:3.9-eclipse-temurin-21` | Dockerfile build stage |
| ☐ | `eclipse-temurin:21-jre-alpine` | Dockerfile runtime stage |
| ☐ | `zaproxy/zap-stable:2.17.0` | Phase 2 DAST (~1 GB pull) |
| ☐ | `prom/prometheus:v2.54.1` | Phase 4 |
| ☐ | `prom/alertmanager:v0.27.0` | Phase 4 |
| ☐ | `grafana/grafana:11.2.0` | Phase 4 |
| ☐ | `prom/node-exporter:v1.8.2` | Phase 4 |

Pulling them before the session removes the slowest, most variable step.

## 5. Required ports

| Port | Interface | Used by |
|---|---|---|
| 22 | all | SSH, Vagrant, ufw rule |
| 8080 | all | Jenkins |
| 18080 | all | acceptance container (`DEPLOY_CONTAINER`) |
| 18081 | all | production container (`PROD_DEPLOY`) |
| 3000 | all | Grafana (the only monitoring UI published outside the VM) |
| 9090 | `127.0.0.1` | Prometheus |
| 9093 | `127.0.0.1` | Alertmanager |
| 9100 | `127.0.0.1` | node_exporter |

`config-safety-check.sh` fails on any *unexpected* port on all interfaces; the loopback
ones are filtered out by design. `ss -ltnp` tells you which process owns a surprise port.

## 6. Expected resources

| Resource | Need |
|---|---|
| RAM | ~1.5 GB Jenkins + Maven; ZAP ~1 GB; monitoring stack capped at 960 MB (512+256+128+64); app ~400 MB. `RUN_SONAR` needs ~2 GB extra — keep it off |
| Disk | ~6 GB (images ≈ 4 GB, Trivy DB ≈ 130 MB, NVD data ≈ 1 GB, Maven repo ≈ 500 MB) |
| Time | Phase 1 first run is NVD/Trivy-download bound (10–20 min); later builds reuse the caches |

## 7. Known limitation — NVD authentication

☐ Understood and accepted before the session starts.

* Dependency-Check currently fails with `Invalid API Key` while the same key works outside
  Jenkins. The stage is **skipped**, never relaxed: `RUN_DEPENDENCY_CHECK=false`.
* `RUN_TRIVY_FS=true` still scans the same dependency set, at the same CRITICAL gate, with
  no API key.
* Report it as **BLOCKED**, not PASS. Do not describe a skipped scan as a clean scan.
* Resolution steps: [final-validation-guide.md](final-validation-guide.md) §8.

## 8. Exact manual test order

| Order | Build | Parameters set to `true` | Expected result |
|---|---|---|---|
| 1 | Phase 1 | `RUN_DEPENDENCY_CHECK`*, `RUN_TRIVY_FS` | 10 tests, Gitleaks clean, DC report (or BLOCKED), Trivy fs clean, hadolint 0 |
| 2 | Phase 2 | `RUN_DEPENDENCY_CHECK`*, `RUN_TRIVY_FS`, `BUILD_IMAGE`, `TRIVY_SCAN`, `DEPLOY_CONTAINER`, `ZAP_SCAN`, `ACCEPTANCE_TESTS`, `INFRA_TEST`, `COMPLIANCE_CHECK` | acceptance 11/11, compliance 9/9, ZAP 0 FAIL |
| 3 | Phase 3 | `BUILD_IMAGE`, `PROD_DEPLOY`, `SECURITY_SMOKE`, `CONFIG_SAFETY` | smoke 13/13, config 8/8, key never printed |
| 4 | Phase 4 | `BUILD_IMAGE`, `DEPLOY_CONTAINER`, `MONITORING` | monitoring 14/14, dashboard visible, one alert firing |

\* leave `RUN_DEPENDENCY_CHECK` off while the NVD key is rejected. Every other parameter
stays `false`; all fourteen are listed per phase in the validation guide so nothing is left
at its default by accident.

## 9. External prerequisites

| Checkbox | Item |
|---|---|
| ☐ | Network access from the VM to Maven Central, Docker Hub, `services.nvd.nist.gov` |
| ☐ | ~15 GB free on the VM disk before the first run |
| ☐ | A second terminal (or SSH tunnel) to inspect Prometheus/Alertmanager on loopback |
| ☐ | No real production system is involved anywhere: "production" is a local container |

## 10. Status vocabulary used in the report

| Verdict | Meaning |
|---|---|
| **IMPLEMENTED** | code/configuration exists and is committed |
| **STATICALLY VERIFIED** | `bash -n`, ShellCheck, Groovy parse, YAML/JSON/XML parse, diff review |
| **RUNTIME-TESTED** | observed in a Jenkins build on the VM, with console/report evidence |
| **BLOCKED** | could not run for an environmental reason (NVD key, missing credential) |
| **NOT TESTED** | never ran in this revision; never report it as passing |

## 11. Current status of the four phases

| Phase | Implemented | Statically verified | Runtime-tested |
|---|---|---|---|
| 1 — Development | yes | yes | partly: build, tests, Gitleaks, Trivy fs observed in build #11; Dependency-Check **BLOCKED** (NVD) |
| 2 — Acceptance | yes | yes | yes, build #11: image built, image scan 0 CRITICAL, ZAP 66 PASS / 0 FAIL / 2 WARN, acceptance 11/11 |
| 3 — Production | yes | yes | **no** |
| 4 — Operations | yes | yes | **no** |

## 12. After the session

1. Fill the `[À REMPLIR: résultat réel du scan]` placeholders in `docs/rapport-final.md`
   with the numbers actually observed.
2. Capture the screenshots listed in `docs/captures/README.md`.
3. Record every non-green stage as BLOCKED or FAIL with its console line — not as "almost
   passing".
