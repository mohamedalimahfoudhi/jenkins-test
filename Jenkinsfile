// DevSecOps pipeline - Phase 1: Development
// Extends the original pipeline (checkout + "Show date") with build, test,
// secrets, dependency, Dockerfile and SAST stages.
//
// Prerequisites in Jenkins:
//   Manage Jenkins > Global Tool Configuration:
//     JDK              name: jdk21
//     Maven            name: maven
//     Dependency-Check name: dependency-check   (Install automatically)
//   VM binaries on PATH: gitleaks, hadolint (see docs/development-setup.md)
//   Plugins: OWASP Dependency-Check, SonarQube Scanner, JUnit,
//            HTML Publisher, Timestamper.
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

    parameters {
        booleanParam(
            name: 'RUN_SONAR',
            defaultValue: false,
            description: 'Run the SonarQube SAST stage and wait for its quality gate. Needs a SonarQube server named "SonarQube" under Manage Jenkins > System.'
        )
        // Phase 2 (Acceptance). Heavy stages default to on but can be switched
        // off individually; see docs/phase2-ordering for the memory reasoning.
        booleanParam(name: 'BUILD_IMAGE',       defaultValue: true, description: 'Phase 2: build the Docker image.')
        booleanParam(name: 'TRIVY_SCAN',        defaultValue: true, description: 'Phase 2: scan the image with Trivy, fail on CRITICAL.')
        booleanParam(name: 'DEPLOY_CONTAINER',  defaultValue: true, description: 'Phase 2: run the app container on a Docker network (host port 18080).')
        booleanParam(name: 'ZAP_SCAN',          defaultValue: true, description: 'Phase 2: OWASP ZAP baseline DAST against the running container.')
        booleanParam(name: 'ACCEPTANCE_TESTS',  defaultValue: true, description: 'Phase 2: scripted security acceptance tests (status codes + headers).')
        booleanParam(name: 'INFRA_TEST',        defaultValue: true, description: 'Phase 2: infrastructure test of the VM.')
        booleanParam(name: 'COMPLIANCE_CHECK',  defaultValue: true, description: 'Phase 2: Dockerfile/Jenkinsfile compliance policy check.')
        // Phase 3 (Production). PROD_DEPLOY needs the 'app-api-key' Jenkins credential.
        booleanParam(name: 'PROD_DEPLOY',       defaultValue: false, description: 'Phase 3: deploy the production container with secrets injected from Jenkins credentials.')
        booleanParam(name: 'SECURITY_SMOKE',    defaultValue: true, description: 'Phase 3: post-deployment security smoke tests.')
        booleanParam(name: 'CONFIG_SAFETY',     defaultValue: true, description: 'Phase 3: configuration safety checks (ports, non-root user, runtime secrets).')
        // Phase 4 (Operations). The stack needs roughly 1 GB of RAM, so it is off
        // for ordinary builds and switched on for the demo.
        booleanParam(name: 'MONITORING',        defaultValue: false, description: 'Phase 4: start Prometheus/Grafana/Alertmanager and verify metrics, dashboards and alerts.')
    }

    options {
        timestamps()
        skipDefaultCheckout(true)
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '10'))
    }

    stages {

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
                sh '''
                    set -u
                    FAILED=0

                    check() {
                        label="$1"; shift
                        if output="$("$@" 2>&1)"; then
                            printf 'OK    %-24s %s\n' "$label" "$(printf '%s' "$output" | head -n 1)"
                        else
                            printf 'FAIL  %-24s command not found or failed: %s\n' "$label" "$*"
                            FAILED=1
                        fi
                    }

                    check "jdk (tool jdk21)"   java -version
                    check "maven (tool maven)" mvn -v
                    check "gitleaks"           gitleaks version
                    check "hadolint"           hadolint --version

                    if [ "$FAILED" -ne 0 ]; then
                        echo "--------------------------------------------------------------"
                        echo "Preflight failed, so no security stage ran and no report exists."
                        echo "Fix: install the missing binary in the VM (docs/development-setup.md,"
                        echo "section 2), then check the names under Manage Jenkins > Global Tool"
                        echo "Configuration (jdk21, maven, dependency-check)."
                        exit 1
                    fi
                    echo "Preflight passed: every tool the security stages need is on PATH."
                '''
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
            steps {
                // VERIFY: odcInstallation must match the tool name configured
                // in Global Tool Configuration.
                dependencyCheck odcInstallation: 'dependency-check',
                        nvdCredentialsId: 'nvd-api-key',
                        additionalArguments: '--format XML --format HTML'
            }
            post {
                always {
                    // Fail only on CVSS >= 9.0 (Critical). High/Medium/Low are
                    // reported but do not fail the build.
                    dependencyCheckPublisher pattern: 'dependency-check-report.xml', failedTotalCritical: 1
                    archiveArtifacts artifacts: 'dependency-check-report.*', allowEmptyArchive: true
                    publishHTML(target: [
                        allowMissing      : true,
                        alwaysLinkToLastBuild: true,
                        keepAll           : true,
                        reportDir         : '.',
                        reportFiles       : 'dependency-check-report.html',
                        reportName        : 'Dependency-Check report'
                    ])
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

        // ---------------- Phase 2: Acceptance ----------------
        // Order matters on a 4 GB VM: build -> scan image -> deploy -> DAST ->
        // acceptance -> cleanup. SonarQube (last) and ZAP are the two memory
        // hogs; keep RUN_SONAR off and ZAP_SCAN off when you need a fast build.

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
                sh '''
                    set -o pipefail
                    mkdir -p reports
                    bash scripts/infra-check.sh | tee reports/infra-report.txt
                '''
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

        // ---------------- Phase 3: Production ----------------

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
                    CONTAINER=devsecops-prod bash scripts/config-safety-check.sh | tee reports/config-safety-report.txt
                '''
            }
            post {
                always {
                    archiveArtifacts artifacts: 'reports/config-safety-report.txt', allowEmptyArchive: true
                }
            }
        }

        // ---------------- Phase 4: Operations ----------------

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

        // Runs only when the build is started with RUN_SONAR checked.
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
            // Phase 2 containers are disposable; remove them even when a stage failed.
            sh '''
                if command -v docker >/dev/null 2>&1; then
                    docker rm -f devsecops-app devsecops-prod >/dev/null 2>&1 || true
                    docker network rm devsecops-net >/dev/null 2>&1 || true
                fi
            '''
            archiveArtifacts artifacts: 'reports/**', allowEmptyArchive: true
        }
        success {
            echo 'Phase 1 pipeline finished: build, tests, secrets, dependencies, Dockerfile and (optionally) SAST.'
        }
        failure {
            echo 'Phase 1 pipeline failed - see the first failing stage above.'
        }
    }
}
