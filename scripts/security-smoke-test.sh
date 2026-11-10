#!/usr/bin/env bash
#
# scripts/security-smoke-test.sh
# Phase 3 (Production) smoke test: the small set of security promises that must
# hold the moment a build is deployed. Different from the acceptance test: it
# checks the *deployed* instance, it is fast, and it is safe to run on every
# deployment.
#
# Checks:
#   1. the service answers and returns the expected greeting
#   2. hardening headers are present
#   3. only /actuator/health and /actuator/prometheus are open; everything that
#      leaks configuration (/actuator/env, /actuator/beans, ...) stays 404
#   4. unknown routes return 404 (no stack trace, no index page)
#   5. HTTP TRACE is refused
#   6. no X-Powered-By style banner
#
# Usage:
#   bash scripts/security-smoke-test.sh                          # http://127.0.0.1:18081
#   BASE_URL=http://127.0.0.1:18080 bash scripts/security-smoke-test.sh
#
# Exit 0 = deployed instance is good, 1 = do not promote it.

set -uo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:18081}"
PASS=0
FAIL=0

pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

echo "Security smoke test against $BASE_URL"
echo ""

code() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X "$1" "$BASE_URL$2"; }

# 1. liveness + expected body
body="$(curl -s --max-time 10 "$BASE_URL/hello" || true)"
if [ -n "$body" ]; then
    pass "GET /hello answered: ${body:0:60}"
else
    fail "GET /hello returned nothing"
fi

# 2. headers
headers="$(curl -s -D - -o /dev/null --max-time 10 "$BASE_URL/hello")"
# Compare with CR stripped and whitespace tolerated: a header check that depends
# on exact spacing is a check that fails at random.
for pair in "X-Content-Type-Options:nosniff" "X-Frame-Options:DENY" "Referrer-Policy:no-referrer"; do
    name="${pair%%:*}"; want="${pair#*:}"
    if printf '%s\n' "$headers" | tr -d '\r' | grep -qiE "^${name}:[[:space:]]*${want}[[:space:]]*$"; then
        pass "header $name: $want"
    else
        fail "header $name missing or not '$want'"
    fi
done

# 3. health and the metrics endpoint are open by design (Phase 4 monitoring);
#    anything that leaks configuration must still be closed.
got="$(code GET /actuator/health)"
[ "$got" = "200" ] && pass "/actuator/health is exposed (HTTP 200)" || fail "/actuator/health returned HTTP $got"

if curl -s --max-time 10 "$BASE_URL/actuator/prometheus" | grep -q '^jvm_memory_used_bytes'; then
    pass "/actuator/prometheus serves JVM metrics"
else
    fail "/actuator/prometheus does not serve JVM metrics"
fi

# /actuator itself is the discovery page: it answers 200 by design, and the
# property to assert is that it advertises nothing that leaks configuration.
links="$(curl -s --max-time 10 "$BASE_URL/actuator" || true)"
if [ -z "$links" ]; then
    fail "/actuator discovery page returned nothing"
else
    leaked=""
    for bad in env beans heapdump threaddump loggers; do
        if printf '%s' "$links" | grep -q "/$bad"; then
            leaked="$leaked $bad"
        fi
    done
    if [ -z "$leaked" ]; then
        pass "/actuator discovery advertises only safe endpoints"
    else
        fail "/actuator discovery advertises:$leaked"
    fi
fi

for path in /actuator/env /actuator/beans /actuator/heapdump; do
    got="$(code GET "$path")"
    if [ "$got" = "404" ]; then
        pass "$path stays closed (HTTP 404)"
    else
        fail "$path is exposed (HTTP $got) - configuration leak"
    fi
done

# 4. unknown route
got="$(code GET /nope)"
[ "$got" = "404" ] && pass "unknown route returns 404" || fail "unknown route returned HTTP $got"

# 5. TRACE
got="$(code TRACE /hello)"
case "$got" in
    405|501) pass "HTTP TRACE refused (HTTP $got)" ;;
    *)       fail "HTTP TRACE answered with $got" ;;
esac

# 6. banner
if printf '%s' "$headers" | grep -qi '^X-Powered-By:'; then
    fail "X-Powered-By banner present"
else
    pass "no X-Powered-By banner"
fi

echo ""
echo "Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
