#!/usr/bin/env bash
# Diagnose why per-tool HTML reports do or do not appear in the LEFT SIDEBAR of
# the Jenkins job page. Run this ON THE VM (it reads the local JENKINS_HOME).
#
# Usage:
#   bash scripts/jenkins-report-diagnose.sh [JENKINS_URL] [JOB_NAME]
#
#   JENKINS_URL   default http://127.0.0.1:8080
#   JOB_NAME      default devsecops-pipeline
#   JENKINS_AUTH  user:apiToken  if anonymous read is disabled
#   JENKINS_HOME  default /var/lib/jenkins (or the first readable of ~jenkins/...)
#
# Background, from the plugin source (htmlpublisher 1.3x):
#   * the BUILD page links come from HTMLBuildAction on that build;
#   * the JOB page links come from WorkflowActionsFactory, a TransientActionFactory
#     that reads the actions of job.getLastSuccessfulBuild() only;
#   * each job-page link points at lastBuild when alwaysLinkToLastBuild is true,
#     else lastSuccessfulBuild, and is hidden while its directory does not exist.
# So a job with no successful build shows NO job-page links, however many reports
# its failed builds published.
set -uo pipefail

BASE="${1:-http://127.0.0.1:8080}"
JOB="${2:-devsecops-pipeline}"
AUTH=()
[ -n "${JENKINS_AUTH:-}" ] && AUTH=(-u "$JENKINS_AUTH")

if [ -z "${JENKINS_HOME:-}" ]; then
    for candidate in /var/lib/jenkins "$HOME/jenkins_home" /home/jenkins; do
        [ -r "$candidate/jobs" ] && JENKINS_HOME="$candidate" && break
    done
fi
JOB_DIR=""
[ -n "${JENKINS_HOME:-}" ] && JOB_DIR="$JENKINS_HOME/jobs/$JOB"

HERE="$(cd "$(dirname "$0")/.." && pwd)"
RENDERER="$HERE/scripts/render-reports.py"
expected=0
if [ -f "$RENDERER" ] && command -v python3 >/dev/null 2>&1; then
    expected="$(python3 "$RENDERER" --list | wc -l | tr -d ' ')"
fi

echo "Jenkins      : $BASE"
echo "Job          : $JOB"
echo "JENKINS_HOME : ${JENKINS_HOME:-(not found - running HTTP-only)}"
echo "Expected reports: ${expected:-unknown}"

echo
echo "== 1. HTML Publisher plugin =="
plugin=""
if [ -n "${JENKINS_HOME:-}" ]; then
    plugin="$(ls -d "$JENKINS_HOME/plugins/htmlpublisher" 2>/dev/null | head -1)"
fi
if [ -n "$plugin" ]; then
    ver="$(sed -n 's/^Implementation-Version: //p' "$plugin/META-INF/MANIFEST.MF" 2>/dev/null | head -1)"
    echo "installed: htmlpublisher ${ver:-version unknown} ($plugin)"
else
    echo "NOT found under ${JENKINS_HOME:-$JENKINS_HOME}/plugins/htmlpublisher (or JENKINS_HOME unreadable)"
    echo "Install it: Manage Jenkins > Plugins > Available > HTML Publisher"
fi

echo
echo "== 2. What the job builds (SCM and branch) =="
if [ -n "$JOB_DIR" ] && [ -r "$JOB_DIR/config.xml" ]; then
    tr -d '\r' < "$JOB_DIR/config.xml" \
      | sed -n '/<scm>/,/<\/scm>/p' \
      | grep -E '<url>|<name>|<spec>|revision' | sed 's/^[[:space:]]*/  /' | head -8
    grep -o "<scriptPath>[^<]*</scriptPath>" "$JOB_DIR/config.xml" 2>/dev/null | sed 's/^/  /'
else
    echo "cannot read $JOB_DIR/config.xml"
fi

echo
echo "== 3. Builds and the report directories they published =="
last_build="" ; last_success=""
if [ -n "$JOB_DIR" ]; then
    [ -e "$JOB_DIR/lastBuild" ] && last_build="$(basename "$(readlink -f "$JOB_DIR/lastBuild")")"
    [ -e "$JOB_DIR/lastSuccessfulBuild" ] && last_success="$(basename "$(readlink -f "$JOB_DIR/lastSuccessfulBuild")")"
    printf '  lastBuild=%s  lastSuccessfulBuild=%s\n' "${last_build:-none}" "${last_success:-none}"
    echo "  build  result    htmlreports/ entries"
    for dir in $(ls -1d "$JOB_DIR"/builds/* 2>/dev/null | sort -V | tail -6); do
        n="$(basename "$dir")"
        # Jenkins writes <result>SUCCESS</result>; older/plugins may use result="..."
        result="$(tr -d '\r' < "$dir/build.xml" 2>/dev/null \
            | grep -o '<result>[A-Z]*</result>\|result="[A-Z]*"' | head -1 \
            | sed 's/<result>//; s/<\/result>//; s/result="//; s/"//')"
        count="$(ls -1 "$dir/htmlreports" 2>/dev/null | wc -l | tr -d ' ')"
        printf '  #%-6s %-9s %s\n' "$n" "${result:-running}" "$count"
    done
fi

echo
echo "== 4. Links actually rendered on the job page =="
page="$(mktemp)"; trap 'rm -f "$page"' EXIT
code="$(curl -sS -L -o "$page" -w '%{http_code}' "${AUTH[@]}" "$BASE/job/$JOB/" || echo 000)"
echo "  GET /job/$JOB/ -> HTTP $code"
links=0
if [ "$code" = "200" ]; then
    # report links look like /job/<job>/<sanitized report name>/ and are not core actions
    mapfile -t found < <(grep -o "href=\"[^\"]*/job/$JOB/[^/\"]*/\"" "$page" \
        | sed 's/^href="//; s/"$//' | sort -u \
        | grep -vE "/(buildTimeTrend|changes|configure|delete|rename|pipeline-syntax|workspace|build|lastBuild|lastSuccessfulBuild|lastCompletedBuild|scm|api|jobConfigHistory)(/|\"|$)")
    links="${#found[@]}"
    printf '  %s report link(s) on the job page\n' "$links"
    for link in "${found[@]:0:30}"; do printf '    %s\n' "$link"; done
fi

echo
echo "== 5. Verdict =="
if [ -z "${plugin:-}" ]; then
    echo "  CAUSE: HTML Publisher is not installed. Nothing else can show a link."
    echo "  FIX  : install htmlpublisher, then rebuild."
    exit 1
fi
if [ -z "${last_success:-}" ]; then
    echo "  CAUSE: this job has never had a SUCCESSFUL build."
    echo "         The plugin builds the job-page links from lastSuccessfulBuild only,"
    echo "         so a job whose builds all fail shows none, even though each failed"
    echo "         build page lists its reports."
    echo "  FIX  : get one green build. Safe parameters for a first green run:"
    echo "         BUILD_IMAGE=true TRIVY_SCAN=true DEPLOY_CONTAINER=true ZAP_SCAN=false"
    echo "         RUN_DEPENDENCY_CHECK=false RUN_TRIVY_FS=true RUN_SONAR=false"
    echo "         PROD_DEPLOY=false MONITORING=false"
    echo "         (RUN_DEPENDENCY_CHECK=false SKIPS that stage; it does not weaken it.)"
    exit 1
fi
if [ "$links" -eq 0 ]; then
    echo "  CAUSE: a successful build exists (#$last_success) but carries no HTML report"
    echo "         actions, so the plugin has nothing to put on the job page."
    echo "         That is what happens when the pipeline Jenkins builds has no"
    echo "         publishHTML step - i.e. the reporting Jenkinsfile is not the one"
    echo "         being built (check section 2)."
    echo "  FIX  : commit the reporting Jenkinsfile to the branch the job builds, or"
    echo "         point the job's Repository URL at the checkout that has it, then"
    echo "         run one green build."
    exit 1
fi
if [ "${expected:-0}" -gt 0 ] && [ "$links" -lt "$expected" ]; then
    echo "  CAUSE: the job page shows $links of $expected reports. Build #$last_success"
    echo "         published only those, so it predates the reporting change."
    echo "  FIX  : run one green build with the reporting Jenkinsfile, then re-check."
    exit 1
fi
echo "  OK: $links report link(s) are on the job page."
echo "  Next: bash scripts/verify-jenkins-reports.sh $BASE $JOB"
