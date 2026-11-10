#!/usr/bin/env bash
#
# scripts/monitoring-check.sh
# Phase 4 (Operations) verification: proves the monitoring stack is not just
# running, but actually receiving metrics, loading alert rules and serving the
# dashboard.
#
# Checks:
#   1. Prometheus is ready and the application target is UP
#   2. JVM metrics arrive from the application
#   3. the alert rules are loaded
#   4. Grafana is healthy (and, if the admin password is available, that the
#      provisioned dashboard exists)
#   5. Alertmanager is ready
#   6. the application still exposes metrics while keeping config endpoints closed
#
# Usage:
#   bash scripts/monitoring-check.sh
#
# The Grafana admin password is read from monitoring/.env (0600, gitignored,
# written by install-phase4.sh), never from an argument: it must not show up in
# the process list or in the Jenkins console. MONITORING_ENV_FILE overrides the
# path (used by the tests).
#
# Exit 0 = monitoring is working, 1 = it is not.

set -uo pipefail

PROM_URL="${PROM_URL:-http://127.0.0.1:9090}"
GRAFANA_URL="${GRAFANA_URL:-http://127.0.0.1:3000}"
ALERT_URL="${ALERT_URL:-http://127.0.0.1:9093}"
APP_URL="${APP_URL:-http://127.0.0.1:18080}"
APP_JOB="${APP_JOB:-devsecops-app}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/monitoring/docker-compose.yml}"
ENV_FILE="${MONITORING_ENV_FILE:-$ROOT_DIR/monitoring/.env}"

if [ -z "${GRAFANA_ADMIN_PASSWORD:-}" ] && [ -r "$ENV_FILE" ]; then
    GRAFANA_ADMIN_PASSWORD="$(sed -n 's/^GRAFANA_ADMIN_PASSWORD=//p' "$ENV_FILE" | head -1)"
fi

PASS=0
FAIL=0
pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }
info() { printf 'INFO  %s\n' "$1"; }

echo "Operations check"
echo "  prometheus  : $PROM_URL"
echo "  grafana     : $GRAFANA_URL"
echo "  alertmanager: $ALERT_URL"
echo "  application : $APP_URL"
echo ""

code_of() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$1"; }

# Returns the value of a PromQL instant query, or "none"/"error".
prom_value() {
    curl -s --max-time 10 -G --data-urlencode "query=$1" "$PROM_URL/api/v1/query" \
    | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    result = data.get("data", {}).get("result", [])
    print(result[0]["value"][1] if result else "none")
except Exception:
    print("error")
'
}

# 1. Prometheus + target
[ "$(code_of "$PROM_URL/-/ready")" = "200" ] \
    && pass "Prometheus is ready" \
    || fail "Prometheus is not ready at $PROM_URL"

up="$(prom_value "up{job=\"$APP_JOB\"}")"
case "$up" in
    1) pass "application target is UP (job=$APP_JOB)" ;;
    none) fail "application target '$APP_JOB' does not exist - is the container running?" ;;
    *) fail "application target is not UP (up=$up)" ;;
esac

# 2. real JVM metrics
heap="$(prom_value "count(jvm_memory_used_bytes{job=\"$APP_JOB\"})")"
case "$heap" in
    error|none) fail "no JVM metrics from the application" ;;
    *) if [ "$heap" -gt 0 ] 2>/dev/null; then pass "JVM metrics are being scraped ($heap series)"; else fail "JVM metrics empty"; fi ;;
esac

# 3. alert rules
rules_json="$(curl -s --max-time 10 "$PROM_URL/api/v1/rules")"
rule_report="$(printf '%s' "$rules_json" | python3 -c '
import json, sys
try:
    groups = json.load(sys.stdin).get("data", {}).get("groups", [])
    names = [r.get("name") for g in groups for r in g.get("rules", [])]
    print(f"{len(names)}|{",".join(names)}")
except Exception:
    print("0|")
')"
rule_count="${rule_report%%|*}"
rule_names="${rule_report#*|}"
if [ "$rule_count" -gt 0 ] 2>/dev/null; then
    pass "alert rules loaded: $rule_count ($rule_names)"
else
    fail "no alert rules are loaded in Prometheus"
fi
for expected in ApplicationDown HighErrorRate SlowResponses NodeDown; do
    case ",$rule_names," in
        *",$expected,"*) pass "alert rule present: $expected" ;;
        *) fail "alert rule missing: $expected" ;;
    esac
done

# 4. Grafana
ghealth="$(curl -s --max-time 10 "$GRAFANA_URL/api/health")"
gdb="$(printf '%s' "$ghealth" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("database", "unknown"))
except Exception:
    print("unreachable")
')"
[ "$gdb" = "ok" ] && pass "Grafana healthy (database=ok)" || fail "Grafana health: $gdb"

if [ -n "${GRAFANA_ADMIN_PASSWORD:-}" ]; then
    found="$(curl -s --max-time 10 -u "admin:${GRAFANA_ADMIN_PASSWORD}" \
        "$GRAFANA_URL/api/search?query=DevSecOps" \
        | python3 -c '
import json, sys
try:
    print(sum(1 for d in json.load(sys.stdin) if "DevSecOps" in d.get("title", "")))
except Exception:
    print("0")
')"
    [ "$found" -gt 0 ] 2>/dev/null \
        && pass "provisioned Grafana dashboard is present" \
        || fail "provisioned Grafana dashboard not found"
else
    info "no readable $ENV_FILE - skipped the authenticated dashboard check"
fi

# 4b. exposure model: only Grafana may be published outside the VM
if [ -f "$COMPOSE_FILE" ]; then
    published_ok=1
    for expected in '"0.0.0.0:3000:3000"' '"127.0.0.1:9090:9090"' '"127.0.0.1:9093:9093"' '"127.0.0.1:9100:9100"'; do
        grep -qF -- "$expected" "$COMPOSE_FILE" || published_ok=0
    done
    leaked="$(grep -E '^\s+- "([0-9.:]+:)?(9090|9093|9100):' "$COMPOSE_FILE" | grep -v '127\.0\.0\.1:' || true)"
    if [ "$published_ok" -eq 1 ] && [ -z "$leaked" ]; then
        pass "only Grafana is published outside the VM; other ports are loopback"
    else
        fail "compose publishes non-Grafana ports outside the VM:${leaked:- binding missing}"
    fi
else
    info "compose file not found - skipped the exposure check"
fi

# 5. Alertmanager
[ "$(code_of "$ALERT_URL/-/ready")" = "200" ] \
    && pass "Alertmanager is ready" \
    || fail "Alertmanager is not ready at $ALERT_URL"

# 6. application endpoints: metrics open, configuration closed
# Captured before matching: `curl | grep -q` can SIGPIPE curl into a false FAIL.
metrics="$(curl -s --max-time 10 "$APP_URL/actuator/prometheus" || true)"
if grep -q '^jvm_memory_used_bytes' <<<"$metrics"; then
    pass "application exposes /actuator/prometheus"
else
    fail "application does not expose /actuator/prometheus at $APP_URL"
fi
env_code="$(code_of "$APP_URL/actuator/env")"
[ "$env_code" = "404" ] \
    && pass "/actuator/env stays closed (HTTP 404)" \
    || fail "/actuator/env is exposed (HTTP $env_code)"

# currently firing alerts are informational: a downloaded build legitimately
# leaves ApplicationDown firing because the pipeline removes its containers.
firing="$(curl -s --max-time 10 "$PROM_URL/api/v1/alerts" | python3 -c '
import json, sys
try:
    alerts = json.load(sys.stdin).get("data", {}).get("alerts", [])
    print(", ".join(a.get("labels", {}).get("alertname", "?") for a in alerts) or "none")
except Exception:
    print("unknown")
')"
info "alerts currently firing: $firing"

echo ""
echo "Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
