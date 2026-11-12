# What was verified outside the VM (and what cannot be)

> **Update — Jenkins build #11 on the VM (Phase 2 only).** Since this file was written,
> one real Jenkins build has exercised the acceptance phase: image built, Trivy image
> scan 0 CRITICAL, container deployed, ZAP baseline 66 PASS / 0 FAIL / 2 WARN,
> acceptance tests 11/11. Phase 3 (production deploy, smoke, configuration safety) and
> Phase 4 (monitoring) have still never run on the VM, and the NVD API key is still
> rejected there — Dependency-Check is skipped, never weakened. The pipeline was also
> corrected after this file: every `sh` block that pipes into `tee` now starts with
> `#!/usr/bin/env bash` (dash has no `-o pipefail`), and `monitoring-check.sh` no longer
> uses a Python 3.12-only f-string. Parameter sets and expected output for the remaining
> phases: [final-validation-guide.md](final-validation-guide.md).

Verdicts used below and in the rest of the documentation: **IMPLEMENTED** (code exists),
**STATICALLY VERIFIED** (syntax/lint/parse gates only), **RUNTIME-TESTED** (observed in a
Jenkins build on the VM), **BLOCKED** (environmental prerequisite missing), **NOT TESTED**
(never ran). A local simulation or a harness with stubbed binaries is *statically
verified* at best — never runtime-tested.

This file exists so no result is ambiguous. It records **exactly** what was executed in the
development environment where the pipeline was written, with the observed output, and it
names what that environment physically cannot run. Anything not in the "executed" table is
not verified here and must be captured on the VM.

Development environment: Ubuntu 24.04, JDK 21.0.13, Maven 3.6.3, Docker **CLI only**
(no daemon), no Jenkins, no SonarQube.

> **Provenance, read this before quoting a number.** Every result below was produced in
> this development environment, **not** by a Jenkins build on the VM. In particular the
> nine-CVE finding (§2) comes from a `trivy` run here, before the upgrade; Jenkins has
> never produced a Trivy or Dependency-Check result. The French report and the slides mark
> every scan result as `[À REMPLIR: résultat réel du scan]` for that reason. What this
> file does prove is that the scripts, the pipeline file and the application behave as
> claimed — it does not substitute for the VM's build.

---

## 1. Executed, with results

| # | Check | Tool / version | Result |
|---|---|---|---|
| 1 | Build + full test suite | Maven 3.6.3, JDK 21 | **BUILD SUCCESS, 10 tests, 0 failures** |
| 2 | Secrets scan, whole history | gitleaks **8.30.1** | **0 findings** (16 commits, ~189 KB scanned) |
| 3 | Dockerfile lint | hadolint **2.15.1** | **0 findings** |
| 4 | Shell script lint | shellcheck **0.11.0** (`--severity=warning`) | **0 findings** (one real SC2034 fixed, see §3) |
| 5 | Syntax of every shell script | `bash -n` | **0 errors** across 12 scripts + `pre-commit` hook |
| 6 | Dependency vulnerabilities | trivy **0.76.2** (`fs`, vuln scanner) | **0 vulnerabilities** after the upgrade — 9 CRITICAL before it (§2) |
| 7 | Compose validity + published ports | Docker Compose 2.40.3 | **valid**; 3000 on `0.0.0.0`, 9090/9093/9100 on `127.0.0.1` |
| 8 | Prometheus / Alertmanager / Grafana provisioning | PyYAML 6.0.3 | 5 YAML documents parsed; **6 alert rules**, 3 scrape jobs |
| 9 | Grafana dashboard structure | JSON parse | **6 panels**, all with expressions, uid `devsecops-overview` |
| 10 | Jenkinsfile syntax + structure | Groovy 4.0.24 | parses; **21 stages, 14 parameters**; pre-existing stage names unchanged |
| 11 | Actuator surface of the running jar | `java -jar` on 18080 | `/actuator` 200, `/actuator/health` 200, `/actuator/prometheus` 200 (JVM metrics), `/actuator/env` `/beans` `/heapdump` **404** |
| 12 | Security smoke test | `scripts/security-smoke-test.sh` | **13 passed, 0 failed** |
| 13 | Security acceptance test | `scripts/security-acceptance-test.sh` | **11 passed, 0 failed** |
| 14 | Monitoring checks | `scripts/monitoring-check.sh` against stand-in Prometheus/Grafana/Alertmanager | **14 passed, 0 failed** |
| 15 | Compliance check | `scripts/compliance-check.sh` | **9 passed, 0 failed** |
| 16 | Configuration safety check | `scripts/config-safety-check.sh` | **fails closed** without a container (`0 passed, 1 failed`) — correct behaviour, it refuses to certify what it cannot inspect |
| 17 | Infrastructure check | `scripts/infra-check.sh` | **6 passed, 7 failed** — expected: this host is not the VM (no Jenkins on 8080, no `/opt/dependency-check`) |
| 18 | Negative tests | scripts run against deliberately broken inputs | a compose publishing `9090:9090` → **FAIL**; a discovery page advertising `/env` → **FAIL**; a Prometheus that is not ready → **FAIL**; an empty dependency list → SBOM generator **exits 1** (fails closed) |
| 19 | Dependency scan without an API key (new stage) | trivy **0.76.2** `sbom` on the 62 resolved components | scan reaches the Java target; **0 CRITICAL** after the upgrade. `trivy fs .` alone was rejected: it reads `pom.xml` only and would pass vacuously (§3) |

The checks in rows 12–15 and 18 are the same scripts the pipeline runs; only their targets
are stand-ins here (a Python HTTP stub for Prometheus/Grafana/Alertmanager, the real jar for
the application).

---

## 2. Dependency vulnerability found here, and fixed

The first real `trivy fs` scan found **9 CRITICAL vulnerabilities**, all inherited from
Spring Boot **3.3.5**:

| Package | Installed | Fixed in |
|---|---|---|
| `org.apache.tomcat.embed:tomcat-embed-core` | 10.1.31 | 10.1.35 (CVE-2025-24813) and 10.1.55–10.1.58 (CVE-2026-41293, -43512, -43515, -55276, -65182, -65905, -68525) |
| `org.springframework:spring-webmvc` | 6.1.14 | 7.0.9 only (CVE-2026-47884, RCE via `XsltView`) |

Because the pipeline's image scan is `trivy image --severity CRITICAL --exit-code 1`, that
build would have gone **red on the VM** — the gate was doing its job on a two-year-old
framework release.

**Fix applied:** parent upgraded `3.3.5` → **`4.1.2`**, which manages spring-framework
**7.0.10** and tomcat **11.0.27** — at or above every fixed version above. One test-side
change was required: Boot 4 moved `@AutoConfigureMockMvc` to
`org.springframework.boot.webmvc.test.autoconfigure` and into the new
`spring-boot-starter-webmvc-test` module.

**Proof of remediation:** the same `trivy fs` scan after the upgrade reports
**"no vulnerabilities found"** (0 CRITICAL, 0 HIGH, 0 MEDIUM), and all 10 tests, the 13
smoke checks and the 11 acceptance checks still pass on the upgraded jar.

This is the kind of finding that belongs in the report as a result, not as a footnote: the
pipeline detected a real critical exposure in its own application and forced a fix.

---

## 3. Defects fixed while verifying here

| Defect | Consequence | Fix |
|---|---|---|
| `curl … \| grep -q` under `pipefail` | grep closes the pipe on first match; curl dies of SIGPIPE (141) → intermittent false FAIL of the smoke test | capture the response body first, then match |
| `/actuator` asserted as 404 | it is the discovery page and answers 200, so the check could never be right | assert that its body advertises no sensitive endpoint |
| `/actuator/prometheus` asserted in MockMvc | metrics export is disabled in that test context, so the endpoint is never registered | assertion lives in the live smoke test instead |
| `post` removed `devsecops-net` while monitoring was attached | Prometheus loses its scrape target | remove the network only when nothing is attached |
| unused loop variable in `install-phase4.sh` | shellcheck warning | `for _ in ...` |
| MockMvc annotation moved | Boot 4 test compilation failure | new package + new test starter (§2) |
| `install-dependency-check.sh` died on a fresh Ubuntu | `unzip` is not installed by default; the python3 fallback does not restore the executable bit, so the layout test (`-x`) failed | install `unzip` idempotently with apt-get, test the file with `-f`, and `chmod +x` after extraction |
| Dependency-Check stage aborted before scanning (seen on the VM's first build) | the plugin's `dependencyCheck` step resolved its tool to `null` and printed `ERROR: Couldn't find any executable in "null"`, so nothing was analysed and the whole build stopped there | the stage runs the CLI installed by `scripts/install-dependency-check.sh` (`--failOnCVSS 9`), needs no Jenkins tool registration, and the NVD key travels in a 0600 property file because Jenkins runs `sh` with `-x` |
| `trivy fs .` would have been a false gate | it reads `pom.xml`, where `spring-boot-starter-parent` supplies the versions, and Trivy's fs scanner does not open jars (`language-specific files num=0`) | resolve the real set with `mvn dependency:list`, convert it to a CycloneDX SBOM, scan that with `trivy sbom`; the converter exits 1 on an empty list |

---

## 4. Not executable in this environment

These require the VM; each is covered by a numbered capture in
[`captures/README.md`](captures/README.md):

| Not run here | Why | Where it is proven |
|---|---|---|
| `docker build` / `trivy image` | no Docker daemon (CLI present, no socket) | Jenkins stage *Container image* / *Container scan* |
| OWASP ZAP baseline | needs a running container | Jenkins stage *DAST* |
| Real Prometheus, Alertmanager, Grafana, node_exporter | needs the daemon; validated as configuration only here | captures 19–23 |
| Alert delivery / `ApplicationDown` firing | needs the real stack | capture 23 |
| Jenkins stages themselves | no Jenkins in this environment | capture 25 |
| SonarQube quality gate | server not installed (optional) | — (declared optional) |
| OWASP Dependency-Check | CLI not installed; NVD data needs network quota + API key | Jenkins stage *Dependency scan* |
| `ufw`, `fail2ban`, `unattended-upgrades` | host firewalling of the VM itself | captures 13–15, 24 |

---

## 5. Reproducing this verification

```bash
mvn -B -ntp clean package                 # 10 tests
gitleaks git --redact --verbose           # secrets, whole history
hadolint --no-color Dockerfile            # Dockerfile
shellcheck --severity=warning scripts/*.sh .githooks/pre-commit
trivy fs --scanners vuln .                # dependency CVEs
docker compose -f monitoring/docker-compose.yml --env-file monitoring/.env config -q

java -jar target/devops-demo-0.0.1-SNAPSHOT.jar --server.port=18080 &
BASE_URL=http://127.0.0.1:18080 bash scripts/security-smoke-test.sh
BASE_URL=http://127.0.0.1:18080 bash scripts/security-acceptance-test.sh
bash scripts/compliance-check.sh
```

The versions above are the ones actually executed; `docs/tools-table.md` records how each
tool is obtained and pinned.
