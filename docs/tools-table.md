# Tool inventory — what runs, in which version, and why

Every tool the pipeline calls, with the version actually in use, how it gets
there, and what happens when it finds something. This is the table to reproduce
in the report: **nothing here is a version I guessed** — each row names where the
number comes from.

---

## 1. Inventory

| Tool | Version | Phase | Role in the pipeline | Obtained by | Gate (fails when) |
|---|---|---|---|---|---|
| Jenkins | **2.580.2** | all | Orchestrator | Vagrant VM, port 8080 | — |
| OpenJDK (JDK) | **21** | 1, 2 | Build and test toolchain; project targets Java 17 | VM package / Jenkins tool `jdk21` | Compile or test error |
| Apache Maven | **3.6.3** | 1, 2 | Build, test, SonarQube goal | VM package / Jenkins tool `maven` | Build fails |
| Spring Boot | **4.1.2** | 1 | Application framework (parent POM); brings spring-framework 7.0.10 and tomcat 11.0.27 | `pom.xml` | — |
| JUnit 5 | managed by Boot 4.1.2 | 1 | Unit and security-behaviour tests (10 tests) | `spring-boot-starter-test` | Any test fails |
| Spring Boot webmvc test support | managed by Boot 4.1.2 | 1 | `@AutoConfigureMockMvc`: Boot 4 moved it out of `starter-test` into its own module | `spring-boot-starter-webmvc-test` | Compilation of the tests |
| Micrometer Prometheus registry | managed by Boot 4.1.2 | 4 | Exposes `/actuator/prometheus` | `pom.xml` | — |
| gitleaks | **8.30.1** | 1 | Secrets scan over the whole git history | `scripts/install-tools.sh` → `/usr/local/bin`, **sha256 verified** against the project's `checksums.txt` | Any finding |
| OWASP Dependency-Check | **13.0.0** | 1 | Software composition analysis (known CVEs in dependencies) | `scripts/install-dependency-check.sh` → `/opt/dependency-check`, **sha256 pinned** in the script | Any CVSS ≥ 9.0 |
| hadolint | **2.15.1** | 1 | Dockerfile lint | `scripts/install-tools.sh` → `/usr/local/bin`, **sha256 verified** against `checksums.sha256` | Any lint finding |
| Docker Engine + buildx + Compose v2 | Ubuntu package set from Docker's apt repo | 2, 3, 4 | Build/run containers, compose stack | `scripts/install-phase2.sh`, vendor GPG key + `signed-by` | Container does not start |
| Trivy | Aqua apt repository (current at install time) | 1, 2 | Image CVE scan; dependency scan of the resolved set through a CycloneDX SBOM (stage *Dependency scan (Trivy fs)*), which needs no API key and no Docker | `scripts/install-phase2.sh`, vendor GPG key | Any **CRITICAL** finding |
| OWASP ZAP | **2.17.0** (`zaproxy/zap-stable:2.17.0`) | 2 | Baseline DAST against the running container | `scripts/install-phase2.sh` (image pull) | A ZAP `FAIL` rule (warnings do not fail: `-I`) |
| SonarQube | `sonarqube:community` (floating tag, optional) | 1 | SAST + quality gate, only with `RUN_SONAR` | `scripts/install-phase2.sh` (optional pull) | Quality gate not OK |
| ufw | Ubuntu 22.04 package | 3 | Host firewall; SSH allowed before enabling | `scripts/install-phase3.sh` | — (checked by `config-safety-check.sh`) |
| fail2ban | Ubuntu 22.04 package | 3 | SSH brute-force detection (HID) | `scripts/install-phase3.sh`, jail `devsecops.local` | — |
| unattended-upgrades | Ubuntu 22.04 package | 3 | Automatic security patching | `scripts/install-phase3.sh` | — |
| Prometheus | **v2.54.1** | 4 | Metrics collection | `monitoring/docker-compose.yml` (pinned tag) | — |
| Alertmanager | **v0.27.0** | 4 | Alert routing/grouping | `monitoring/docker-compose.yml` (pinned tag) | — |
| Grafana | **11.2.0** | 4 | Dashboards (provisioned datasource + dashboard) | `monitoring/docker-compose.yml` (pinned tag) | — |
| node_exporter | **v1.8.2** | 4 | Host CPU/memory/disk metrics | `monitoring/docker-compose.yml` (pinned tag) | — |
| bash, curl, python3, ss | Ubuntu 22.04 | all | Script runtime (all checks are plain bash + `curl`; `python3` only parses JSON) | VM | — |

Two Jenkins credentials are consumed, not tools: `nvd-api-key` (NVD API key for
Dependency-Check) and `app-api-key` (runtime secret for the production
container). Neither value appears in the repository or in the Jenkinsfile.

---

## 2. How versions were pinned (and where they are not)

* **Verified before pinning.** The four monitoring image tags were checked with
  `docker manifest inspect` against the registry, so each tag exists and is
  what the report claims.
* **Checksums where the project publishes one.** gitleaks and hadolint archives
  are verified against the checksum files released with them.
* **One measured checksum.** Dependency-Check publishes a PGP signature but no
  `.sha256` sidecar, so `install-dependency-check.sh` pins the SHA-256 measured
  when 13.0.0 was chosen (`DC_SHA256`, overridable with `DC_SHA256=...`).
* **Container images use explicit tags, never `latest`** — except the optional
  SonarQube image, which follows upstream's `community` tag (see limitations).
* **Apt packages are not version-pinned.** Docker, Trivy and the Phase 3
  packages come from signed vendor/Ubuntu repositories and are installed at
  whatever version that repository serves on the day. Re-running the install
  script later may therefore install a newer build. This is stated, not hidden:
  `infra-check.sh` prints the versions actually present on the VM, and those
  printed versions are the ones to quote.

---

## 3. Why these tools (and not the alternatives)

| Choice | Rejected alternative | Reason |
|---|---|---|
| gitleaks (standalone binary) | gitleaks Jenkins plugin | Standalone binary is one version, checksum-verified, identical locally (pre-commit hook) and in CI |
| Dependency-Check **CLI** | `dependency-check-maven` plugin | Maven **3.6.3** cannot run plugin 13.x (needs a newer Maven); the CLI gives the same report without upgrading Maven |
| hadolint (standalone) | Dockerfile lint in SonarQube | Runs in one second, no server needed, and the rule set is the industry default |
| Trivy for the **image** | Dependency-Check only | Dependency-Check sees libraries; Trivy sees the OS packages inside the image too |
| ZAP **baseline** scan | ZAP full scan | A full scan needs a long-running job and much more RAM; the baseline is the honest fit for a 4 GB VM |
| fail2ban for HID | OSSEC / Wazuh | OSSEC needs a manager and ~200 MB extra RAM on a box that already runs Jenkins; fail2ban covers the actual threat (SSH brute force) with one jail |
| Prometheus + Grafana + Alertmanager | ELK stack | Pull-based metrics and a provisioned dashboard are far lighter than an ELK stack on 4 GB |
| Provisioned Grafana (files in git) | Clicking a dashboard in the UI | The dashboard is reproducible: clone, install, and it exists — no manual step to forget |

---

## 4. Known limitations (quote these honestly)

1. **Trivy, Docker and the Phase 3 packages are not version-pinned.** They come
   from signed apt repositories. Pinning them would mean freezing Ubuntu's
   package versions, which fights the unattended-upgrades policy installed in
   Phase 3. The report should say "installed from the vendor's signed
   repository" rather than claim an exact version.
2. **SonarQube uses a floating `community` tag** and is optional. It is excluded
   from the default build for memory reasons, so its version is whatever was
   pulled last.
3. **Dependency-Check's checksum was measured, not published.** It detects a
   corrupted or substituted download relative to that measurement, not relative
   to an upstream signature.
4. **The monitoring stack was validated as configuration, not as a running
   system** in the environment where these files were written (no Docker daemon
   available). Container-level behaviour — scraping by container name, dashboard
   rendering, alert delivery — is verified on the VM and must be screenshotted
   there.
5. **No tool here is a substitute for a real CD setup:** the image is never
   pushed to a registry, and "production" is a second container on the same VM.
6. **The nine-CVE finding came from a development environment, not from Jenkins.**
   A `trivy` run on the machine where the pipeline was written reported 9 CRITICAL
   vulnerabilities in Spring Boot 3.3.5 (Tomcat 10.1.31, spring-webmvc 6.1.14); the
   parent was moved to 4.1.2 and the same scan then reported none. The gate was not
   relaxed — the dependency was fixed (`docs/verification-here.md` §2). Quote the build's
   own result in the report, not this one.
7. **Trivy's fs scanner does not open jars,** and this project inherits its versions
   from `spring-boot-starter-parent`, so `trivy fs .` on `pom.xml` alone would report
   nothing whatever the classpath contains. That is why the stage scans a CycloneDX SBOM
   generated from Maven's resolved dependency list (`scripts/generate-sbom.py`, which
   fails closed on an empty list) instead of trusting a vacuous result.

---

## 5. Reproducing the toolchain

```bash
sudo bash scripts/install-tools.sh              # gitleaks, hadolint (checksum-verified)
sudo bash scripts/install-dependency-check.sh   # Dependency-Check CLI (pinned sha256)
sudo bash scripts/install-phase2.sh             # docker, trivy, ZAP/SonarQube images
sudo bash scripts/install-phase3.sh             # ufw, fail2ban, unattended-upgrades
sudo bash scripts/install-phase4.sh             # monitoring stack (only Grafana published)
bash scripts/infra-check.sh                     # prints what is actually installed
```

`docs/pipeline-overview.md` covers the stages these tools run in, the order, and
what each one is allowed to fail the build on.
