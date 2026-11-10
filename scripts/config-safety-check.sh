#!/usr/bin/env bash
#
# scripts/config-safety-check.sh
# Phase 3 (Production) configuration safety check, run after a deployment.
# It inspects the running container and the host, not the application code.
#
# Checks:
#   1. the container is running
#   2. it runs as a numeric, non-root user
#   3. the image is not tagged :latest
#   4. the container is not privileged, not on host networking, and does not
#      mount the docker socket
#   5. secrets are injected at runtime, not baked in: APP_API_KEY is set in the
#      environment and is not the example placeholder
#   6. only expected ports are bound on all interfaces
#
# Values of environment variables are never printed - only set/unset.
#
# Usage:
#   bash scripts/config-safety-check.sh
#   CONTAINER=devsecops-prod APP_PORT=18081 bash scripts/config-safety-check.sh
#
# Exit 0 = configuration is safe enough to keep, 1 = fix before promoting.

set -uo pipefail

CONTAINER="${CONTAINER:-devsecops-prod}"
APP_PORT="${APP_PORT:-18081}"
EXPECTED_PORTS="${EXPECTED_PORTS:-22 8080 18080 18081}"
PASS=0
FAIL=0

pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }
info() { printf 'INFO  %s\n' "$1"; }

echo "Configuration safety check (container: $CONTAINER)"
echo ""

command -v docker >/dev/null 2>&1 || { echo "FAIL  docker not available - cannot inspect the container"; exit 1; }

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    fail "container '$CONTAINER' is not running"
    echo ""
    echo "Result: $PASS passed, $FAIL failed"
    exit 1
fi
pass "container '$CONTAINER' is running"

# 2. user
user_field="$(docker inspect "$CONTAINER" --format '{{.Config.User}}')"
if [ -z "$user_field" ]; then
    fail "no USER set in the container - it runs as root"
else
    uid="${user_field%%:*}"
    case "$uid" in
        ''|*[!0-9]*) fail "container user '$user_field' is not numeric" ;;
        0)           fail "container runs as root (uid 0)" ;;
        *)           pass "container runs as uid $uid (non-root)" ;;
    esac
fi

# 3. image tag
image="$(docker inspect "$CONTAINER" --format '{{.Config.Image}}')"
case "$image" in
    *:latest) fail "image '$image' uses the :latest tag" ;;
    *)        pass "image '$image' is not :latest" ;;
esac

# 4. privileges
priv="$(docker inspect "$CONTAINER" --format '{{.HostConfig.Privileged}}')"
[ "$priv" = "false" ] && pass "container is not privileged" || fail "container is privileged"

netmode="$(docker inspect "$CONTAINER" --format '{{.HostConfig.NetworkMode}}')"
[ "$netmode" != "host" ] && pass "container is not using host networking ($netmode)" || fail "container uses host networking"

if docker inspect "$CONTAINER" --format '{{range .Mounts}}{{.Source}} {{end}}' | grep -q '/var/run/docker.sock'; then
    fail "docker socket is mounted into the container"
else
    pass "docker socket is not mounted into the container"
fi

# 5. secrets injected, not baked in
envdump="$(docker inspect "$CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}')"
api_key="$(printf '%s\n' "$envdump" | sed -n 's/^APP_API_KEY=//p')"
if [ -z "$api_key" ]; then
    fail "APP_API_KEY is not set in the container environment"
elif [ "$api_key" = "replace-me" ]; then
    fail "APP_API_KEY still holds the .env.example placeholder"
else
    pass "APP_API_KEY is set at runtime (value not printed, ${#api_key} characters)"
fi
if printf '%s\n' "$envdump" | grep -qiE '^(PASSWORD|SECRET|TOKEN)[A-Z_]*=.+'; then
    info "additional secret-like variables present (values not printed)"
fi

# 6. listening ports
if command -v ss >/dev/null 2>&1; then
    unexpected=""
    while read -r port; do
        [ -n "$port" ] || continue
        case " $EXPECTED_PORTS " in
            *" $port "*) : ;;
            *) unexpected="$unexpected $port" ;;
        esac
    done < <(ss -ltnH 2>/dev/null | awk '$4 ~ /^(0\.0\.0\.0|\*|\[::\]):/ { split($4, a, ":"); print a[length(a)] }' | sort -u)

    if [ -n "$unexpected" ]; then
        fail "unexpected ports listening on all interfaces:$unexpected (expected:$EXPECTED_PORTS)"
    else
        pass "only expected ports listen on all interfaces:$EXPECTED_PORTS"
    fi
else
    info "ss not available - skipped the port check"
fi

echo ""
echo "Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
