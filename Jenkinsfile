// DevSecOps pipeline - consolidated, phases 1 to 4.
//
// One pipeline covers the whole course project:
//   Phase 1 Development  build, unit tests, secrets scan, dependency scan,
//                        Dockerfile lint
//   Phase 2 Acceptance   image build + scan, container deploy, DAST, security
//                        acceptance tests, infrastructure test, compliance
//   Phase 3 Production   production deploy with an injected secret, security
//                        smoke test, configuration safety check
//   Phase 4 Operations   metrics, dashboards and alerting
//
// Stage-by-stage reference, parameters and failure playbook: docs/pipeline-overview.md
// Tool inventory and pinned versions:                        docs/tools-table.md
//
// Prerequisites in Jenkins:
//   Manage Jenkins > Global Tool Configuration:
//     JDK   name: jdk21
//     Maven name: maven
//   Manage Jenkins > Credentials:
//     nvd-api-key  (secret text) - NVD API key for Dependency-Check
//     app-api-key  (secret text) - runtime secret for the production container
//   Manage Jenkins > Plugins:
//     SonarQube Scanner, JUnit, HTML Publisher, Timestamper, Credentials Binding
//     (the OWASP Dependency-Check plugin is NOT required: its tool registration came
//      back empty on the VM and aborted the build with "Couldn't find any executable
//      in null", so the stage runs the CLI installed by scripts/install-dependency-check.sh)
//   VM binaries on PATH: gitleaks, hadolint, trivy, docker
//   VM install: /opt/dependency-check/bin/dependency-check.sh (scripts/install-dependency-check.sh)
// (Preflight checks java, mvn, gitleaks, hadolint, trivy and python3 before any stage,
//  so a missing scanner is reported once instead of inside a security stage.)
//   (see docs/development-setup.md for the install scripts)
//
// Steps marked VERIFY should be confirmed once in
// Dashboard > <job> > Pipeline Syntax > Snippet Generator, because parameter
// names differ between plugin versions.

pipeline {
    agent any

    tools {
        jdk 'jdk21'
        maven 'maven'
    }

    // Every heavy or risky stage is a switch. Defaults are chosen so that an
    // ordinary build is safe to run on a 4 GB VM: SonarQube, the production
    // deploy and the monitoring stack are off until asked for.
    parameters {
        // ---- Phase 1 ----
        booleanParam(
            name: 'RUN_SONAR',
            defaultValue: false,
            description: 'SAST: run the SonarQube analysis and wait for its quality gate. Needs a SonarQube server named "SonarQube" under Manage Jenkins > System, and roughly 2 GB of free RAM.'
        )
        booleanParam(
            name: 'RUN_DEPENDENCY_CHECK',
            defaultValue: true,
            description: 'Phase 1: OWASP Dependency-Check, the NVD-backed SCA stage. Needs a valid NVD API key (credential nvd-api-key). Turn it off only while that key is rejected: the stage is then skipped, not weakened, and the Trivy fs scan below still covers the same dependencies without any API key.'
        )
        booleanParam(
            name: 'RUN_TRIVY_FS',
            defaultValue: true,
            description: 'Phase 1: Trivy fs scan of the resolved application dependencies. No API key, no NVD feed; fails on CRITICAL.'
        )

        // ---- Phase 2 (Acceptance) ----
        booleanParam(name: 'BUILD_IMAGE',       defaultValue: true,  description: 'Phase 2: build the Docker image.')
        booleanParam(name: 'TRIVY_SCAN',        defaultValue: true,  description: 'Phase 2: scan the image with Trivy, fail on CRITICAL.')
        booleanParam(name: 'DEPLOY_CONTAINER',  defaultValue: true,  description: 'Phase 2: run the app container on a Docker network (host port 18080).')
        booleanParam(name: 'ZAP_SCAN',          defaultValue: true,  description: 'Phase 2: OWASP ZAP baseline DAST against the running container.')
        booleanParam(name: 'ACCEPTANCE_TESTS',  defaultValue: true,  description: 'Phase 2: scripted security acceptance tests (status codes + headers).')
        booleanParam(name: 'INFRA_TEST',        defaultValue: true,  description: 'Phase 2: infrastructure test of the VM.')
        booleanParam(name: 'COMPLIANCE_CHECK',  defaultValue: true,  description: 'Phase 2: Dockerfile/Jenkinsfile compliance policy check.')

        // ---- Phase 3 (Production) ----
        booleanParam(name: 'PROD_DEPLOY',       defaultValue: false, description: 'Phase 3: deploy the production container with secrets injected from Jenkins credentials.')
        booleanParam(name: 'SECURITY_SMOKE',    defaultValue: true,  description: 'Phase 3: post-deployment security smoke tests.')
        booleanParam(name: 'CONFIG_SAFETY',     defaultValue: true,  description: 'Phase 3: configuration safety checks (ports, non-root user, runtime secrets).')

        // ---- Phase 4 (Operations) ----
        booleanParam(name: 'MONITORING',        defaultValue: false, description: 'Phase 4: start Prometheus/Grafana/Alertmanager and verify metrics, dashboards and alerts.')
    }

    options {
        timestamps()
        skipDefaultCheckout(true)
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '10'))
    }

    stages {

        // ===================== Phase 1: Development =====================

        // Same first stage as the original pipeline.
        stage('Checkout') {
            steps {
                checkout scm
                sh 'git log --oneline -5'
            }
        }

        // Fails fast, with one clear message, when a tool the later security
        // stages need is missing - instead of dying inside that security stage.
        stage('Preflight (tool checks)') {
            steps {
                // The parameters are handed to the shell as environment variables so
                // the script stays a plain single-quoted string (Groovy would otherwise
                // interpolate the shell's own $variables), while the checks can still
                // depend on what this particular build will actually run.
                withEnv([
                    "RUN_DEPENDENCY_CHECK=${params.RUN_DEPENDENCY_CHECK}",
                    "RUN_TRIVY_FS=${params.RUN_TRIVY_FS}",
                    "TRIVY_SCAN=${params.TRIVY_SCAN}",
                    "NEEDS_DOCKER=${params.BUILD_IMAGE || params.TRIVY_SCAN || params.DEPLOY_CONTAINER || params.ZAP_SCAN || params.PROD_DEPLOY || params.CONFIG_SAFETY || params.SECURITY_SMOKE || params.MONITORING}"
                ]) {
                    sh '''
                        set -u
                        FAILED=0
                        DC_HOME="${DC_HOME:-/opt/dependency-check}"

                        check() {
                            label="$1"; shift
                            if output="$("$@" 2>&1)"; then
                                printf 'OK    %-24s %s\n' "$label" "$(printf '%s' "$output" | head -n 1)"
                            else
                                printf 'FAIL  %-24s command not found or failed: %s\n' "$label" "$*"
                                FAILED=1
                            fi
                        }

                        check_path() {
                            if [ -x "$2" ]; then
                                printf 'OK    %-24s %s\n' "$1" "$2"
                            else
                                printf 'FAIL  %-24s not executable: %s\n' "$1" "$2"
                                FAILED=1
                            fi
                        }

                        # Needed by every build.
                        check "jdk (tool jdk21)"   java -version
                        check "maven (tool maven)" mvn -v
                        check "gitleaks"           gitleaks version
                        check "hadolint"           hadolint --version

                        # Needed only by the stages THIS build runs. A tool the build
                        # does not use must not stop it: with RUN_DEPENDENCY_CHECK off
                        # the NVD-backed CLI is not required at all.
                        if [ "$RUN_TRIVY_FS" = "true" ] || [ "$TRIVY_SCAN" = "true" ]; then
                            check "trivy"              trivy --version
                        else
                            echo "SKIP  trivy                    both Trivy stages are off in this build"
                        fi
                        if [ "$RUN_TRIVY_FS" = "true" ]; then
                            check "python3"            python3 --version
                        fi
                        if [ "$NEEDS_DOCKER" = "true" ]; then
                            check "docker (daemon)"    docker info
                        else
                            echo "SKIP  docker                  no stage in this build uses Docker"
                        fi
                        if [ "$RUN_DEPENDENCY_CHECK" = "true" ]; then
                            check_path "dependency-check CLI" "$DC_HOME/bin/dependency-check.sh"
                        else
                            echo "SKIP  dependency-check CLI    RUN_DEPENDENCY_CHECK is off (the Trivy scan still runs)"
                        fi

                        if [ "$FAILED" -ne 0 ]; then
                            echo "--------------------------------------------------------------"
                            echo "Preflight failed, so no security stage ran and no report exists."
                            echo "Fix on the VM, then rebuild:"
                            echo "  gitleaks, hadolint    : sudo bash scripts/install-tools.sh"
                            echo "  trivy, docker, images : sudo bash scripts/install-phase2.sh"
                            echo "  dependency-check CLI  : sudo bash scripts/install-dependency-check.sh"
                            echo "  docker group          : sudo usermod -aG docker jenkins && sudo systemctl restart jenkins"
                            echo "Tool names must stay jdk21 and maven in Manage Jenkins > Global Tool Configuration."
                            exit 1
                        fi
                        echo "Preflight passed: every tool this build needs is usable."
                    '''
                }
            }
        }

        stage('Build') {
            steps {
                sh 'mvn -B -ntp clean compile'
            }
        }

        stage('Unit and security tests') {
            steps {
                sh 'mvn -B -ntp test'
            }
            post {
                always {
                    junit allowEmptyResults: true, testResults: 'target/surefire-reports/*.xml'
                    archiveArtifacts artifacts: 'target/surefire-reports/*.xml', allowEmptyArchive: true
                }
            }
        }

        // Server-side equivalent of the local pre-commit hook: the hook can be
        // bypassed with --no-verify, this stage cannot. It scans the whole
        // history, so a secret committed earlier is still found.
        stage('Secrets scan (Gitleaks)') {
            steps {
                sh '''
                    set -eu
                    mkdir -p reports
                    gitleaks version
                    gitleaks git \
                        --report-format json \
                        --report-path reports/gitleaks-report.json \
                        --redact \
                        --verbose
                '''
            }
            post {
                always {
                    archiveArtifacts artifacts: 'reports/gitleaks-report.json', allowEmptyArchive: true
                }
            }
        }

        stage('Dependency scan (OWASP Dependency-Check)') {
            // Skipped - never weakened - when the NVD API key is rejected: the
            // gate itself (CVSS >= 9.0) stays in the post block and applies to
            // every build that runs this stage.
            when {
                expression { params.RUN_DEPENDENCY_CHECK }
            }
            steps {
                // Runs the CLI directly instead of the plugin's dependencyCheck
                // step. On the VM that step aborted the whole build with
                //   ERROR: Couldn't find any executable in "null"
                // because the plugin's tool registration had no usable
                // installation, while scripts/install-dependency-check.sh had
                // already installed a working CLI. No plugin tool needed now.
                withCredentials([string(credentialsId: 'nvd-api-key', variable: 'NVD_API_KEY')]) {
                    // Diagnostic only: asks NVD directly with the credential Jenkins
                    // injected, before Dependency-Check touches it. set +x first keeps
                    // the header out of the console; the key is never echoed.
                    sh '''
                        set +x
                        # Trim exactly like the Dependency-Check step below, so this
                        # asks NVD with the value that will actually be sent: a trailing
                        # newline in the credential would otherwise make the header
                        # malformed and produce a misleading 000/403.
                        KEY_DIAG="$(printf '%s' "$NVD_API_KEY" | tr -d '[:space:]')"
                        echo "Checking NVD API key from Jenkins (${#KEY_DIAG} chars)..."
                        curl -sS -o /dev/null -w "Jenkins credential HTTP %{http_code}\n" \
                          -H "apiKey: $KEY_DIAG" \
                          "https://services.nvd.nist.gov/rest/json/cves/2.0?resultsPerPage=1"
                    '''
                    sh '''
                        # set +x immediately: this block expands the NVD secret, and
                        # Jenkins runs sh with -x, whose trace shows the expansion of
                        # every command substitution - including the key.
                        set -eu
                        set +x
                        DC_HOME="${DC_HOME:-/opt/dependency-check}"
                        DC_CLI="$DC_HOME/bin/dependency-check.sh"
                        if [ ! -x "$DC_CLI" ]; then
                            echo "Dependency-Check CLI not found at $DC_CLI"
                            echo "Fix on the VM: sudo bash scripts/install-dependency-check.sh"
                            echo "(or untick RUN_DEPENDENCY_CHECK - the Trivy dependency scan still runs)"
                            exit 1
                        fi
                        mkdir -p reports
                        "$DC_CLI" --version

                        # The CLI scans jars, and spring-boot-starter-parent owns the
                        # versions in pom.xml, so scanning the source tree alone would
                        # find nothing and report a clean project. Resolve what ships.
                        mvn -B -ntp -q dependency:copy-dependencies \
                            -DincludeScope=runtime -DoutputDirectory=target/deps
                        JARS="$(find target/deps -name '*.jar' | wc -l)"
                        if [ "$JARS" -eq 0 ]; then
                            echo "no dependency jar in target/deps - refusing to report a clean scan"
                            exit 1
                        fi
                        echo "scanning $JARS dependency jars with Dependency-Check"

                        # The NVD key goes into a 0600 property file, never on the
                        # command line: Jenkins runs sh with -x, so an argument would
                        # be echoed into this console.
                        #
                        # A trailing newline or space pasted into the Jenkins credential
                        # is the classic cause of "Invalid API Key" while the same key
                        # works from a terminal, so the value is trimmed: an NVD key
                        # never contains whitespace. The value itself is never printed -
                        # only its length.
                        KEY="$(printf '%s' "$NVD_API_KEY" | tr -d '[:space:]')"
                        echo "nvd-api-key credential: ${#NVD_API_KEY} chars raw, ${#KEY} chars after trimming whitespace"
                        case "$KEY" in
                            ????????-????-????-????-????????????) : ;;
                            *)
                                echo "the nvd-api-key credential does not look like an NVD key"
                                echo "(expected four groups 8-4-4-4-12, no quotes, no newline)"
                                echo "Re-enter it under Manage Jenkins > Credentials, or untick RUN_DEPENDENCY_CHECK."
                                exit 1
                                ;;
                        esac

                        umask 077
                        PROPS="$(mktemp)"
                        trap 'rm -f "$PROPS"' EXIT
                        printf 'nvd.api.key=%s\n' "$KEY" > "$PROPS"

                        # --failOnCVSS 9 is the gate: exit non-zero on any CRITICAL.
                        "$DC_CLI" \
                            --project devops-demo \
                            --scan target/deps \
                            --format XML --format HTML \
                            --out reports \
                            --data "$DC_HOME/data" \
                            --propertyfile "$PROPS" \
                            --failOnCVSS 9
                    '''
                }
            }
            post {
                always {
                    archiveArtifacts artifacts: 'reports/dependency-check-report.*', allowEmptyArchive: true
                    publishHTML(target: [
                        allowMissing         : true,
                        alwaysLinkToLastBuild: true,
                        keepAll              : true,
                        reportDir            : 'reports',
                        reportFiles          : 'dependency-check-report.html',
                        reportName           : 'Dependency-Check report'
                    ])
                }
            }
        }

        // Second, independent dependency scan: no API key, no NVD feed, no Docker.
        //
        // Dependency-Check answers "which published CVEs affect these libraries?"
        // from the NVD data and needs a valid key. This stage answers "does any
        // resolved dependency match a CVE in Trivy's own database?" and works
        // offline. Complementary, not redundant: whoever has no working NVD key
        // still scans, and the two databases do not publish on the same day.
        //
        // Why two Trivy commands instead of only `trivy fs .`:
        //   * `trivy fs` reads pom.xml, but spring-boot-starter-parent manages the
        //     versions there, so the file names almost none of them and the scan
        //     reports nothing whatever the classpath contains.
        //   * Trivy's fs scanner does not open jars either (with trivy 0.76.2 it
        //     reports "language-specific files num=0" for target/ and for the fat
        //     jar).
        // So the stage resolves the real dependency set with Maven and scans that
        // through a CycloneDX SBOM. scripts/generate-sbom.py fails closed on an
        // empty list, which is what keeps this gate from passing vacuously.
        stage('Dependency scan (Trivy fs)') {
            when {
                expression { params.RUN_TRIVY_FS }
            }
            steps {
                sh '''
                    set -u
                    mkdir -p reports
                    STATUS=0
                    trivy --version

                    # 1. the repository as it is: pom.xml, lockfiles, manifests
                    trivy fs --scanners vuln --severity CRITICAL --exit-code 1 \
                        --format table -o reports/trivy-fs-report.txt . || STATUS=1
                    cat reports/trivy-fs-report.txt || true

                    # 2. the dependency set actually resolved for the runtime
                    mvn -B -ntp -q dependency:list -DincludeScope=runtime \
                        -DoutputFile=reports/dependencies.txt || STATUS=1
                    python3 scripts/generate-sbom.py \
                        reports/dependencies.txt reports/sbom-cyclonedx.json || STATUS=1
                    trivy sbom --scanners vuln --severity CRITICAL --exit-code 1 \
                        --format table -o reports/trivy-fs-resolved-report.txt \
                        reports/sbom-cyclonedx.json || STATUS=1
                    cat reports/trivy-fs-resolved-report.txt || true

                    # machine-readable versions, archived as evidence
                    trivy fs --scanners vuln --format json \
                        -o reports/trivy-fs-report.json . >/dev/null 2>&1 || true
                    trivy sbom --scanners vuln --format json \
                        -o reports/trivy-fs-resolved-report.json \
                        reports/sbom-cyclonedx.json >/dev/null 2>&1 || true

                    if [ "$STATUS" -ne 0 ]; then
                        echo "Dependency scan failed: CRITICAL findings in the image-independent scan, or the scan could not run."
                    fi
                    exit "$STATUS"
                '''
            }
            post {
                always {
                    archiveArtifacts artifacts: 'reports/trivy-fs-report.*,reports/trivy-fs-resolved-report.*,reports/sbom-cyclonedx.json,reports/dependencies.txt', allowEmptyArchive: true
                }
            }
        }

        stage('Dockerfile lint (hadolint)') {
            steps {
                sh '''
                    set -eu
                    mkdir -p reports
                    hadolint --version
                    set +e
                    hadolint --no-color Dockerfile > reports/hadolint-report.txt 2>&1
                    HADOLINT_EXIT=$?
                    set -e
                    cat reports/hadolint-report.txt
                    exit "$HADOLINT_EXIT"
                '''
            }
            post {
                always {
                    archiveArtifacts artifacts: 'reports/hadolint-report.txt', allowEmptyArchive: true
                }
            }
        }

        // ===================== Phase 2: Acceptance =====================
        // Order matters on a 4 GB VM: build -> scan image -> deploy -> DAST ->
        // acceptance -> cleanup. SonarQube (last) and ZAP are the two memory
        // hogs; keep RUN_SONAR off and ZAP_SCAN off when you need a fast build.
        // Reasoning and the memory budget: docs/pipeline-overview.md.

        stage('Container image (build)') {
            when {
                expression { params.BUILD_IMAGE }
            }
            steps {
                sh '''
                    set -eu
                    mkdir -p reports
                    docker build -t devsecops-demo:ci .
                    docker image inspect devsecops-demo:ci --format '{{.Id}}' > reports/image-id.txt
                    echo "built devsecops-demo:ci ($(cat reports/image-id.txt))"
                '''
            }
            post {
                always {
                    archiveArtifacts artifacts: 'reports/image-id.txt', allowEmptyArchive: true
                }
            }
        }

        stage('Container scan (Trivy)') {
            when {
                expression { params.TRIVY_SCAN }
            }
            steps {
                sh '''
                    set -eu
                    mkdir -p reports
                    trivy --version
                    # Fail the build only on CRITICAL findings; everything is still reported.
                    set +e
                    trivy image --severity CRITICAL --exit-code 1 \
                        --format table -o reports/trivy-report.txt devsecops-demo:ci
                    TRIVY_EXIT=$?
                    set -e
                    trivy image --severity CRITICAL --format json \
                        -o reports/trivy-report.json devsecops-demo:ci >/dev/null 2>&1 || true
                    cat reports/trivy-report.txt || true
                    exit "$TRIVY_EXIT"
                '''
            }
            post {
                always {
                    archiveArtifacts artifacts: 'reports/trivy-report.*', allowEmptyArchive: true
                }
            }
        }

        stage('Deploy application container') {
            when {
                expression { params.DEPLOY_CONTAINER }
            }
            steps {
                sh '''
                    set -eu
                    docker network inspect devsecops-net >/dev/null 2>&1 || docker network create devsecops-net
                    docker rm -f devsecops-app >/dev/null 2>&1 || true
                    # 8080 on the VM belongs to Jenkins, so the app is published on 18080.
                    docker run -d --name devsecops-app --network devsecops-net \
                        -p 18080:8080 devsecops-demo:ci
                    for i in $(seq 1 40); do
                        if curl -fsS http://127.0.0.1:18080/hello >/dev/null 2>&1; then
                            echo "app ready after ${i}s on http://127.0.0.1:18080"
                            exit 0
                        fi
                        sleep 1
                    done
                    echo "app did not become ready in 40s"
                    docker logs devsecops-app || true
                    exit 1
                '''
            }
        }

        stage('DAST (OWASP ZAP baseline)') {
            when {
                expression { params.ZAP_SCAN }
            }
            steps {
                sh '''
                    set -eu
                    mkdir -p reports
                    # ZAP writes into /zap/wrk as its own user; make the mount writable for it.
                    chmod a+w reports
                    docker run --rm --network devsecops-net \
                        -v "$(pwd)/reports:/zap/wrk/:rw" \
                        zaproxy/zap-stable:2.17.0 \
                        zap-baseline.py -t http://devsecops-app:8080/hello \
                            -r zap-report.html -J zap-report.json -I
                '''
            }
            post {
                always {
                    archiveArtifacts artifacts: 'reports/zap-report.*', allowEmptyArchive: true
                    publishHTML(target: [
                        allowMissing         : true,
                        alwaysLinkToLastBuild: true,
                        keepAll              : true,
                        reportDir            : 'reports',
                        reportFiles          : 'zap-report.html',
                        reportName           : 'OWASP ZAP baseline report'
                    ])
                }
            }
        }

        stage('Security acceptance tests') {
            when {
                expression { params.ACCEPTANCE_TESTS }
            }
            steps {
                sh '''
                    set -o pipefail
                    mkdir -p reports
                    BASE_URL=http://127.0.0.1:18080 bash scripts/security-acceptance-test.sh \
                        | tee reports/acceptance-report.txt
                '''
            }
            post {
                always {
                    archiveArtifacts artifacts: 'reports/acceptance-report.txt', allowEmptyArchive: true
                }
            }
        }

        stage('Infrastructure test (VM)') {
            when {
                expression { params.INFRA_TEST }
            }
            steps {
                // The infrastructure test asserts the Dependency-Check CLI only when
                // this build actually runs that stage; otherwise it reports it as
                // information instead of failing the build for an unused tool.
                withEnv(["RUN_DEPENDENCY_CHECK=${params.RUN_DEPENDENCY_CHECK}"]) {
                    sh '''
                        set -o pipefail
                        mkdir -p reports
                        REQUIRE_DEPENDENCY_CHECK="${RUN_DEPENDENCY_CHECK:-1}" \
                            bash scripts/infra-check.sh | tee reports/infra-report.txt
                    '''
                }
            }
            post {
                always {
                    archiveArtifacts artifacts: 'reports/infra-report.txt', allowEmptyArchive: true
                }
            }
        }

        stage('Compliance check (policy)') {
            when {
                expression { params.COMPLIANCE_CHECK }
            }
            steps {
                sh '''
                    set -o pipefail
                    mkdir -p reports
                    bash scripts/compliance-check.sh | tee reports/compliance-report.txt
                '''
            }
            post {
                always {
                    archiveArtifacts artifacts: 'reports/compliance-report.txt', allowEmptyArchive: true
                }
            }
        }

        // ===================== Phase 3: Production =====================

        stage('Deploy production container') {
            when {
                expression { params.PROD_DEPLOY }
            }
            steps {
                // The secret exists only for the duration of this block; it is written
                // to a 0600 temp file for --env-file and deleted immediately after.
                // Docker secrets need Swarm, and on a single host the docker socket is
                // already root-equivalent, so this is the honest option here.
                withCredentials([string(credentialsId: 'app-api-key', variable: 'APP_API_KEY')]) {
                    sh '''
                        set -eu
                        umask 077
                        ENVFILE="$(mktemp)"
                        trap 'rm -f "$ENVFILE"' EXIT
                        printf 'APP_API_KEY=%s\n' "$APP_API_KEY" > "$ENVFILE"
                        docker network inspect devsecops-net >/dev/null 2>&1 || docker network create devsecops-net
                        docker rm -f devsecops-prod >/dev/null 2>&1 || true
                        docker run -d --name devsecops-prod --network devsecops-net \
                            --env-file "$ENVFILE" -p 18081:8080 devsecops-demo:ci
                        for i in $(seq 1 40); do
                            if curl -fsS http://127.0.0.1:18081/hello >/dev/null 2>&1; then
                                echo "production container ready after ${i}s on port 18081"
                                exit 0
                            fi
                            sleep 1
                        done
                        docker logs devsecops-prod || true
                        exit 1
                    '''
                }
            }
        }

        stage('Security smoke tests') {
            when {
                expression { params.SECURITY_SMOKE }
            }
            steps {
                sh '''
                    set -o pipefail
                    mkdir -p reports
                    # Smoke the production container when it exists, otherwise the acceptance one.
                    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx devsecops-prod; then
                        SMOKE_URL=http://127.0.0.1:18081
                    else
                        SMOKE_URL=http://127.0.0.1:18080
                    fi
                    echo "smoke target: $SMOKE_URL"
                    BASE_URL="$SMOKE_URL" bash scripts/security-smoke-test.sh | tee reports/smoke-report.txt
                '''
            }
            post {
                always {
                    archiveArtifacts artifacts: 'reports/smoke-report.txt', allowEmptyArchive: true
                }
            }
        }

        stage('Configuration safety check') {
            when {
                expression { params.CONFIG_SAFETY }
            }
            steps {
                sh '''
                    set -o pipefail
                    mkdir -p reports
                    # The injected secret only exists on the production container.
                    # With PROD_DEPLOY off, check the acceptance container instead
                    # and mark the secret assertion as not applicable there; when
                    # neither container exists the script fails closed.
                    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx devsecops-prod; then
                        CHECK_CONTAINER=devsecops-prod
                        SECRET_REQUIRED=1
                    elif docker ps --format '{{.Names}}' 2>/dev/null | grep -qx devsecops-app; then
                        CHECK_CONTAINER=devsecops-app
                        SECRET_REQUIRED=0
                    else
                        CHECK_CONTAINER=devsecops-prod
                        SECRET_REQUIRED=1
                    fi
                    echo "configuration check target: $CHECK_CONTAINER (runtime secret required: $SECRET_REQUIRED)"
                    CONTAINER="$CHECK_CONTAINER" SECRET_REQUIRED="$SECRET_REQUIRED" \
                        bash scripts/config-safety-check.sh | tee reports/config-safety-report.txt
                '''
            }
            post {
                always {
                    archiveArtifacts artifacts: 'reports/config-safety-report.txt', allowEmptyArchive: true
                }
            }
        }

        // ===================== Phase 4: Operations =====================

        stage('Operations: monitoring stack') {
            when {
                expression { params.MONITORING }
            }
            steps {
                sh 'bash scripts/install-phase4.sh'
            }
        }

        stage('Operations: metrics and alerts check') {
            when {
                expression { params.MONITORING }
            }
            steps {
                sh '''
                    set -o pipefail
                    mkdir -p reports
                    bash scripts/monitoring-check.sh | tee reports/monitoring-report.txt
                '''
            }
            post {
                always {
                    archiveArtifacts artifacts: 'reports/monitoring-report.txt', allowEmptyArchive: true
                }
            }
        }

        // ===================== Optional SAST, last on purpose =====================
        // Listed after the operations stages so the two memory-hungry things
        // (SonarQube server + its scanner, ZAP) never run at the same moment.

        stage('SAST (SonarQube)') {
            when {
                expression { params.RUN_SONAR }
            }
            steps {
                withSonarQubeEnv('SonarQube') {
                    sh 'mvn -B -ntp sonar:sonar'
                }
                timeout(time: 1, unit: 'HOURS') {
                    waitForQualityGate abortPipeline: true
                }
            }
        }
    }

    post {
        always {
            // The application containers are disposable: remove them even when a
            // stage failed, so the next build starts clean and the smoke tests can
            // never talk to a stale container.
            sh '''
                if command -v docker >/dev/null 2>&1; then
                    docker rm -f devsecops-app devsecops-prod >/dev/null 2>&1 || true
                    # Keep the network while the monitoring stack is attached to it:
                    # Prometheus scrapes the app by name through it, and removing it
                    # would break the stack the operations stages just verified.
                    if [ -n "$(docker ps --filter network=devsecops-net --format '{{.Names}}' 2>/dev/null)" ]; then
                        echo "keeping devsecops-net: containers are still attached"
                        docker ps --filter network=devsecops-net --format '  attached: {{.Names}}'
                    else
                        docker network rm devsecops-net >/dev/null 2>&1 || true
                    fi
                fi
            '''
            archiveArtifacts artifacts: 'reports/**', allowEmptyArchive: true
        }
        success {
            echo 'Pipeline finished: build, tests, secrets, dependencies, Dockerfile lint, image scan, DAST, acceptance, production checks and (when enabled) operations.'
        }
        failure {
            echo 'Pipeline failed - the first red stage above is the one to read. Reports from the stages that did run are archived under the build artifacts.'
        }
    }
}
