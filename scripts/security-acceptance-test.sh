#!/usr/bin/env bash
#
# scripts/security-acceptance-test.sh
# Phase 2 acceptance checks against a running instance of the application.
# These are the promises the app must keep before it is promoted:
#
#   1. the happy path still works                        -> 200
#   2. invalid input is rejected                         -> 400
#   3. malformed JSON is rejected                        -> 400
#   4. an internal error does not leak internals         -> 500, no stack trace
#   5. unknown routes are not silently served            -> 404
#   6. hardening headers are present on responses
#
# Usage:
#   bash scripts/security-acceptance-test.sh                      # http://127.0.0.1:18080
#   BASE_URL=http://localhost:8080 bash scripts/security-acceptance-test.sh
#
# Exit code 0 = all checks passed, 1 = at least one failed.

set -uo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:18080}"
PASS=0
FAIL=0

pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

# status_of METHOD PATH [BODY] -> prints the HTTP status code
status_of() {
    local method="$1" path="$2" body="${3:-}"
    if [ -n "$body" ]; then
        curl -s -o /dev/null -w '%{http_code}' -X "$method" \
             -H 'Content-Type: application/json' -d "$body" "$BASE_URL$path"
    else
        curl -s -o /dev/null -w '%{http_code}' -X "$method" "$BASE_URL$path"
    fi
}

expect_status() {
    local label="$1" want="$2" got="$3"
    if [ "$got" = "$want" ]; then pass "$label (HTTP $got)"; else fail "$label (expected $want, got $got)"; fi
}

echo "Security acceptance test against $BASE_URL"
echo ""

# 0. the service answers at all
if ! curl -s -o /dev/null --max-time 10 "$BASE_URL/hello"; then
    echo "FAIL  service unreachable at $BASE_URL"
    exit 1
fi

# 1-5
expect_status "GET /hello"                 200 "$(status_of GET /hello)"
expect_status "POST /api/items (valid)"    200 "$(status_of POST /api/items '{"name":"bolt","quantity":3}')"
expect_status "POST /api/items (blank)"    400 "$(status_of POST /api/items '{"name":"","quantity":3}')"
expect_status "POST /api/items (bad qty)"  400 "$(status_of POST /api/items '{"name":"bolt","quantity":0}')"
expect_status "POST /api/items (bad JSON)" 400 "$(status_of POST /api/items '{"name":"bolt",')"
expect_status "GET /api/boom (sanitised)"  500 "$(status_of GET /api/boom)"
expect_status "GET /nope (unknown route)"  404 "$(status_of GET /nope)"

# 4b. the 500 body must not contain internals
boom_body="$(curl -s "$BASE_URL/api/boom")"
if printf '%s' "$boom_body" | grep -qE 'Exception|com\.example|at [a-z]+\.[a-z]+\.'; then
    fail "error body leaks internals: $boom_body"
else
    pass "error body contains no stack trace or class names"
fi

# 6. hardening headers
headers="$(curl -s -D - -o /dev/null "$BASE_URL/hello")"
check_header() {
    local name="$1" want="$2"
    if printf '%s' "$headers" | grep -qi "^${name}: *${want}"; then
        pass "header $name: $want"
    else
        fail "header $name missing or not '$want'"
    fi
}
check_header "X-Content-Type-Options" "nosniff"
check_header "X-Frame-Options" "DENY"
check_header "Referrer-Policy" "no-referrer"

echo ""
echo "Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
