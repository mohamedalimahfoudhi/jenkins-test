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
