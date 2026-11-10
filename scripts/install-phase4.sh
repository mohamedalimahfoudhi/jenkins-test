#!/usr/bin/env bash
#
# scripts/install-phase4.sh
# Phase 4 (Operations): start the monitoring stack (Prometheus, Alertmanager,
# Grafana, node_exporter) next to the application container.
#
# Safe to re-run: the network is created only if missing, the Grafana password
# is generated once and reused, ufw rules are idempotent and `compose up -d`
# only recreates what changed.
#
# The stack is NOT stopped at the end of a build - it is the thing you show
# during the defence. Stop it with:
#   docker compose -f monitoring/docker-compose.yml down
#
# Usage:
#   bash scripts/install-phase4.sh
#   UI_PORTS="3000 9090" bash scripts/install-phase4.sh   # limit opened ports
#
# The Grafana admin password lands in monitoring/.env (chmod 600, gitignored).
# It is never printed and never committed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$ROOT/monitoring/docker-compose.yml"
ENV_FILE="$ROOT/monitoring/.env"
NETWORK="${NETWORK:-devsecops-net}"
UI_PORTS="${UI_PORTS:-3000 9090 9093 9100}"

log() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "docker is not installed (run scripts/install-phase2.sh)"
docker info >/dev/null 2>&1 || die "cannot reach the docker daemon (root, or the jenkins user in the docker group)"
[ -f "$COMPOSE_FILE" ] || die "missing $COMPOSE_FILE"

# 1. The application may not be running yet, but the external network must exist
#    or compose refuses to start.
if ! docker network inspect "$NETWORK" >/dev/null 2>&1; then
    log "creating docker network $NETWORK"
    docker network create "$NETWORK" >/dev/null
fi

# 2. Grafana password: generated once, 0600, gitignored.
if [ ! -f "$ENV_FILE" ]; then
    umask 077
    password="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
    printf 'GRAFANA_ADMIN_PASSWORD=%s\n' "$password" > "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    log "generated $ENV_FILE with a random Grafana admin password"
else
    log "reusing existing $ENV_FILE"
fi

# 3. Validate the compose file before starting anything.
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" config -q \
    || die "compose file is invalid, nothing was started"

# 4. Open the UI ports (only when a firewall is actually active).
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    for port in $UI_PORTS; do
        if ufw allow "${port}/tcp" >/dev/null 2>&1; then
            log "ufw: allowed ${port}/tcp"
        else
            log "ufw: could not add ${port}/tcp (run this script with sudo to update the firewall)"
        fi
    done
fi

# 5. Start (idempotent).
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d

# 6. Wait for readiness - a started container is not a working service.
wait_for() {
    local url="$1" name="$2" i
    for i in $(seq 1 60); do
        if curl -fsS --max-time 2 "$url" >/dev/null 2>&1; then
            log "$name is ready"
            return 0
        fi
        sleep 2
    done
    log "$name did NOT become ready"
    return 1
}

status=0
wait_for "http://127.0.0.1:9090/-/ready"   "Prometheus"   || status=1
wait_for "http://127.0.0.1:9093/-/ready"   "Alertmanager" || status=1
wait_for "http://127.0.0.1:3000/api/health" "Grafana"     || status=1

if [ "$status" -ne 0 ]; then
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" ps || true
    die "the monitoring stack did not come up cleanly (see 'docker compose logs')"
fi

log ""
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" ps
log ""
log "Grafana     : http://<vm-ip>:3000    (user admin, password in monitoring/.env)"
log "Prometheus  : http://<vm-ip>:9090    (targets: Status > Targets)"
log "Alertmanager: http://<vm-ip>:9093    (alerts appear here when rules fire)"
log "node_exporter metrics: http://<vm-ip>:9100/metrics"
log ""
log "Dashboard 'DevSecOps - Application and host' is provisioned in the DevSecOps folder."
