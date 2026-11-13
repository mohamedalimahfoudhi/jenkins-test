#!/usr/bin/env bash
# Check that every per-tool report link really is on the Jenkins job page,
# and that each one opens the latest build's report.
#
# Usage:
#   bash scripts/verify-jenkins-reports.sh [JENKINS_URL] [JOB_NAME]
#
#   JENKINS_URL   default http://127.0.0.1:8080
#   JOB_NAME      default devsecops-pipeline
#   JENKINS_AUTH  user:apiToken  if the instance needs a login (optional)
#
# Exit code 0 only when every expected link is present on the job page, opens
# with HTTP 200, and shows the report page for the latest build.
#
# It reads the expected link list from scripts/render-reports.py (--list), so
# the names cannot drift from what the pipeline publishes.
set -uo pipefail

BASE="${1:-http://127.0.0.1:8080}"
JOB="${2:-devsecops-pipeline}"
AUTH=()
if [ -n "${JENKINS_AUTH:-}" ]; then
    AUTH=(-u "$JENKINS_AUTH")
fi

HERE="$(cd "$(dirname "$0")/.." && pwd)"
RENDERER="$HERE/scripts/render-reports.py"
command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 2; }
[ -f "$RENDERER" ] || { echo "not found: $RENDERER" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

JOB_PAGE="$TMP/job.html"
code="$(curl -sS -L -o "$JOB_PAGE" -w '%{http_code}' "${AUTH[@]}" "$BASE/job/$JOB/" || echo 000)"
echo "job page     : $BASE/job/$JOB/  (HTTP $code)"
if [ "$code" != "200" ]; then
    echo "Cannot read the job page. Check the URL, the job name, and JENKINS_AUTH." >&2
    exit 1
fi

BUILD_NUMBER="$(curl -sS "${AUTH[@]}" "$BASE/job/$JOB/lastBuild/api/json?tree=number" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("number","?"))' 2>/dev/null || echo '?')"
echo "latest build : #$BUILD_NUMBER"
echo

printf '%-42s %-8s %-6s %s\n' "REPORT (job-page link)" "ON PAGE" "HTTP" "TITLE CHECK"
printf '%s\n' "--------------------------------------------------------------------------------"

missing=0
failed=0
total=0
while IFS=$'\t' read -r urlname title; do
    total=$((total + 1))
    if grep -q "href=\"[^\"]*/$urlname/\"" "$JOB_PAGE"; then on_page="yes"; else on_page="NO"; missing=$((missing + 1)); fi

    body="$TMP/report.html"
    http="$(curl -sS -o "$body" -w '%{http_code}' "${AUTH[@]}" "$BASE/job/$JOB/$urlname/" || echo 000)"
    if [ "$http" = "200" ] && grep -qi "<title>.*${title%% Report}" "$body"; then
        title_ok="ok"
    elif [ "$http" = "200" ]; then
        title_ok="wrong page"
        failed=$((failed + 1))
    else
        title_ok="unreachable"
        failed=$((failed + 1))
    fi
    printf '%-42s %-8s %-6s %s\n' "$title" "$on_page" "$http" "$title_ok"
done < <(python3 "$RENDERER" --list)

echo
echo "expected links : $total"
echo "missing on job page : $missing"
echo "links that did not open the report : $failed"

if [ "$missing" -ne 0 ] || [ "$failed" -ne 0 ]; then
    echo
    echo "Not complete. If the job page lists fewer links than expected:"
    echo "  * the build must have run the post block at least once (it publishes the pages)"
    echo "  * the plugin must be HTML Publisher (htmlpublisher) - Manage Jenkins > Plugins"
    echo "  * publishing needs alwaysLinkToLastBuild: true for a link to exist while a build failed"
    exit 1
fi

echo
echo "OK: every report link is on the job page and opens the latest build's report."
