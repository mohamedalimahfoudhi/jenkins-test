# Phase 1 — Development: setup notes

Everything on this branch, and how to install the two tools the pipeline calls.
Tested versions: gitleaks **8.30.1**, hadolint **2.15.1**, Maven **3.6.3**, JDK **21**.

## 0. What this branch contains

| File | Purpose |
|---|---|
| `docs/threat-model.md` | STRIDE threat model of the REST API |
| `.githooks/pre-commit` | client-side gitleaks hook (blocks a commit containing a secret) |
| `.env.example` | template for environment variables; no real secret |
| `src/main/resources/application.properties` | configuration read from environment variables |
| `src/main/java/com/example/demo/ItemRequest.java` | validated request payload |
| `src/main/java/com/example/demo/ItemController.java` | `POST /api/items` with `@Valid` |
| `src/main/java/com/example/demo/ErrorProbeController.java` | endpoint that throws, for the error test |
| `src/main/java/com/example/demo/ApiExceptionHandler.java` | error handling that never leaks internals |
| `src/test/java/com/example/demo/SecurityBehaviorTests.java` | 6 JUnit 5 security tests |
| `Dockerfile` | multi-stage, JRE 21, non-root numeric user, HEALTHCHECK |
| `Jenkinsfile` | the Phase 1 pipeline |
| `.gitignore` | now also ignores `.env` and `reports/` |

There is deliberately **no `.gitleaks.toml`**: the default rule set covers this repository,
and the config schema changed between gitleaks releases (`[allowlist]` became
`[[allowlists]]` in v8.19+), so adding one would be a version trap. Add one only when you
actually need an allowlist, and check `gitleaks version` first.

## 1. Windows — install gitleaks and enable the hook

**Windows:** download the Windows binary and put it on `PATH` for this session.
(Slow connection: the zip is ~10 MB.)

```powershell
New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\tools\gitleaks" | Out-Null
Invoke-WebRequest -Uri "https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_windows_x64.zip" -OutFile "$env:TEMP\gitleaks.zip"
Expand-Archive -Path "$env:TEMP\gitleaks.zip" -DestinationPath "$env:USERPROFILE\tools\gitleaks" -Force
$env:PATH = "$env:USERPROFILE\tools\gitleaks;$env:PATH"
gitleaks version
```

**Windows:** point Git at the versioned hooks folder (once per clone — this is why the
hook lives in `.githooks/`, not in `.git/hooks/`, which is never committed).

```powershell
cd C:\Users\mahfo\Projects\jenkins-test
git switch devsecops-phase1
git config core.hooksPath .githooks
```

**Windows:** prove the hook blocks a secret. The token is generated, not typed, so no
fake credential is ever written into the repository.

```powershell
$raw   = ([guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')).Substring(0, 36)
$token = "ghp_$raw"
"token = $token" | Set-Content -Encoding ascii config.properties
git add config.properties
git commit -m "test: hook should block this"
```

Expected: the commit is refused, `exit 1`, and gitleaks prints `RuleID: github-pat` with
`pre-commit: BLOCKED`. Clean up afterwards — the file must never be committed:

```powershell
git restore --staged config.properties
Remove-Item config.properties
```

**Screenshot for the report:** the PowerShell window showing the blocked commit and the
`Finding / RuleID: github-pat / File: config.properties` lines.

## 2. VM — install gitleaks and hadolint

Both are standalone binaries; Docker is not needed for either.

**VM:** gitleaks 8.30.1.

```bash
cd /tmp
curl -fL -o gitleaks.tar.gz https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_x64.tar.gz
tar xzf gitleaks.tar.gz gitleaks
sudo install -m 0755 gitleaks /usr/local/bin/gitleaks
gitleaks version
```

**VM:** hadolint 2.15.1.

```bash
cd /tmp
curl -fL -o hadolint https://github.com/hadolint/hadolint/releases/download/v2.15.1/hadolint-linux-x86_64
chmod +x hadolint
sudo install -m 0755 hadolint /usr/local/bin/hadolint
hadolint --version
```

**VM:** confirm both work on this repository.

```bash
cd ~/jenkins-workspace/jenkins-test    # or wherever the job checks out the repo
gitleaks git --redact --verbose
hadolint --no-color Dockerfile
```

**Screenshot:** the two `--version` outputs and a clean `hadolint` run (no output, exit 0).

## 3. Jenkins plugins — verify these names yourself

Under **Manage Jenkins → Plugins → Installed plugins**, filter by each name. The IDs below
are what the update centre uses; the display names are what the pipeline steps need.

| Display name | Plugin ID | Needed for |
|---|---|---|
| OWASP Dependency-Check | `dependency-check-jenkins-plugin` | `dependencyCheck`, `dependencyCheckPublisher` |
| SonarQube Scanner | `sonar` | `withSonarQubeEnv`, `waitForQualityGate` |
| JUnit | `junit` | `junit` step (test report + trend) |
| HTML Publisher | `htmlpublisher` | `publishHTML` (Dependency-Check HTML report) |
| Timestamper | `timestamper` | `options { timestamps() }` |
| Git | `git` | `checkout scm` (already installed — the old job works) |
| Pipeline (Declarative) | `workflow-aggregator` | `pipeline { }` syntax (already installed) |

If a name does not appear, use **Available plugins** and search the display name; do not
guess an ID from this table.

## 4. Jenkins global tools

**Manage Jenkins → Global Tool Configuration:**

- **JDK** named `jdk21` — already configured.
- **Maven** named `maven` — already configured.
- **Dependency-Check** named `dependency-check` — `odcInstallation` in the Jenkinsfile
  must match this name exactly. Use "Install automatically" and let it fetch the CLI
  (needs internet from the VM; note that Dependency-Check 13.x itself wants Maven 3.8.1+,
  which is why the pipeline calls the **Jenkins plugin**, not the Maven plugin).

## 5. Memory and the NVD database on a 4 GB VM

- **First run downloads the NVD data**: the dependency-check documentation states the
  first execution "may take 20 minutes or more" while it downloads and processes the
  National Vulnerability Database; later runs update incrementally (seconds) as long as
  they happen within about seven days.
- **An NVD API key is now effectively required.** Since dependency-check 9.0.0 the tool
  uses the NVD API instead of the data feed, and without a key the updates are "extremely
  slow" (its own wording) and rate-limited. Request one at
  <https://nvd.nist.gov/developers/request-an-api-key> and store it as a Jenkins
  credential, then pass `nvdCredentialsId: '<credential-id>'` to the `dependencyCheck`
  step. Never put the key in the repository.
- **Heap**: the analyzer runs as a separate Java process. On 4 GB total:
  - cap Jenkins itself: in `/etc/default/jenkins` set `JAVA_ARGS="-Xmx1024m"` and restart;
  - run the dependency stage alone — `options { disableConcurrentBuilds() }` is already set,
    so two builds will not analyse at the same time;
  - if the stage still dies with `OutOfMemoryError`, raise the VM to 8 GB
    (`vb.memory = "8192"` in the Vagrantfile, `vagrant reload`). This is the reliable fix;
    4 GB is genuinely tight once SonarQube is added in Phase 2.
- The NVD cache lives in the Jenkins workspace/tool directory; do not delete it between
  builds or you pay the 20-minute download again.

## 6. What was verified, and what was not

Verified in a separate environment with the same versions (JDK 21, Maven 3.6.3):

- `mvn -B -ntp clean test` → BUILD SUCCESS, 7 tests (6 security + 1 context) pass.
- `hadolint --no-color Dockerfile` → no findings, exit 0.
- `gitleaks git` on this repository → no leaks.
- the hook, installed via `core.hooksPath`, blocks a commit containing a fake GitHub token
  and allows a clean commit.

Not verified (cannot be, from here): anything inside your Jenkins — the `Jenkinsfile` has
never been executed by Jenkins 2.580.2, and the `dependencyCheck` / `publishHTML` parameter
names are the documented ones but should be confirmed once in the **Snippet Generator**
(`Dashboard → <job> → Pipeline Syntax → Snippet Generator`).
