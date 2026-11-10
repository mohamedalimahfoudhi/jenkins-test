#!/usr/bin/env bash
#
# scripts/install-phase2.sh
# Phase 2 (Acceptance) tooling for the Jenkins VM:
#   * Docker Engine + buildx + compose, from Docker's official apt repository
#   * the jenkins user added to the docker group
#   * Trivy, from Aqua's official apt repository
#   * pre-pulled images: OWASP ZAP, SonarQube Community, PostgreSQL (for SonarQube)
#
# Big downloads: the image pulls dwarf everything else. ZAP and SonarQube are
# each hundreds of MB to over a GB, PostgreSQL a few hundred MB. Docker itself
# plus Trivy add roughly 100-150 MB.
#
# Integrity: both apt repositories are configured with their vendor GPG key and
# `signed-by`, so every package is signature-verified by apt. Images are pulled
# by tag from Docker Hub, which verifies layer digests.
#
# Idempotent: repositories and keys are only written if missing, packages are
# re-installed by apt in a no-op way, and images are pulled only when absent.
#
# Security trade-off (2 lines, as requested): membership of the `docker` group
# is equivalent to root on this host, because a member can start a privileged
# container and mount / into it. It is required here so the Jenkins pipeline can
# build and run containers; the hardening alternative is a dedicated build agent
# using rootless Docker, which is out of scope for this course project.
#
# Usage:
#   sudo bash scripts/install-phase2.sh
#   sudo SKIP_IMAGES=1 bash scripts/install-phase2.sh          # tooling only
#   sudo WITH_SONARQUBE_SYSCTL=1 bash scripts/install-phase2.sh # also set vm.max_map_count

set -euo pipefail

JENKINS_USER="${JENKINS_USER:-jenkins}"
ZAP_IMAGE="${ZAP_IMAGE:-zaproxy/zap-stable:2.17.0}"
SONAR_IMAGE="${SONAR_IMAGE:-sonarqube:community}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:16-alpine}"
SKIP_IMAGES="${SKIP_IMAGES:-0}"
WITH_SONARQUBE_SYSCTL="${WITH_SONARQUBE_SYSCTL:-0}"

DOCKER_KEY_URL="https://download.docker.com/linux/ubuntu/gpg"
TRIVY_KEY_URL="https://aquasecurity.github.io/trivy-repo/deb/public.key"

log()  { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root: sudo bash scripts/install-phase2.sh"

# shellcheck disable=SC1091
. /etc/os-release
CODENAME="${VERSION_CODENAME:?cannot determine Ubuntu codename from /etc/os-release}"
case "${ID:-}" in
    ubuntu) : ;;
    *) die "this script targets Ubuntu (found ID=${ID:-unknown})" ;;
esac
ARCH="$(dpkg --print-architecture)"
log "Detected: ${PRETTY_NAME:-unknown} ($CODENAME, $ARCH)"

# ---------------------------------------------------------------- Docker -----
if dpkg -s docker-ce >/dev/null 2>&1; then
    log "Docker Engine package already installed - skipping apt install"
else
    log "Adding Docker's official apt repository"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL --retry 3 -o /tmp/docker-repo.gpg "$DOCKER_KEY_URL"
    gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg /tmp/docker-repo.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu %s stable\n' \
        "$ARCH" "$CODENAME" > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

systemctl enable --now docker >/dev/null 2>&1 || warn "could not enable/start docker via systemctl - check: systemctl status docker"

# jenkins -> docker group
if id -nG "$JENKINS_USER" 2>/dev/null | grep -qw docker; then
    log "user '$JENKINS_USER' is already in the docker group"
else
    usermod -aG docker "$JENKINS_USER"
    log "added '$JENKINS_USER' to the docker group"
    warn "group membership only applies to new processes: run 'sudo systemctl restart jenkins' when no build is running"
fi

# ---------------------------------------------------------------- Trivy ------
if command -v trivy >/dev/null 2>&1; then
    log "Trivy already installed - skipping apt install"
else
    log "Adding Aqua's Trivy apt repository"
    install -m 0755 -d /usr/share/keyrings
    curl -fsSL --retry 3 -o /tmp/trivy.key "$TRIVY_KEY_URL"
    gpg --batch --yes --dearmor -o /usr/share/keyrings/trivy.gpg /tmp/trivy.key
    chmod a+r /usr/share/keyrings/trivy.gpg
    printf 'deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb generic main\n' \
        > /etc/apt/sources.list.d/trivy.list
    apt-get update -qq
    apt-get install -y -qq trivy
fi

# ------------------------------------------------------- SonarQube sysctl ----
if [ "$WITH_SONARQUBE_SYSCTL" = "1" ]; then
    log "Setting vm.max_map_count=262144 (required by the Elasticsearch inside SonarQube)"
    printf 'vm.max_map_count=262144\n' > /etc/sysctl.d/99-sonarqube.conf
    sysctl --system >/dev/null
else
    log "Skipping vm.max_map_count (enable with WITH_SONARQUBE_SYSCTL=1 when you actually start SonarQube)"
fi

# ---------------------------------------------------------------- images -----
if [ "$SKIP_IMAGES" = "1" ]; then
    log "SKIP_IMAGES=1 - image pulls skipped"
else
    log ""
    log "Pre-pulling images (this is the slow part on a slow link)"
    for img in "$ZAP_IMAGE" "$SONAR_IMAGE" "$POSTGRES_IMAGE"; do
        if docker image inspect "$img" >/dev/null 2>&1; then
            log "  already present: $img"
        else
            log "  pulling: $img"
            docker pull "$img"
        fi
    done
fi

log ""
log "Installed versions:"
printf '  docker : %s\n' "$(docker --version 2>/dev/null | head -1)"
printf '  compose: %s\n' "$(docker compose version 2>/dev/null | head -1)"
printf '  trivy  : %s\n' "$(trivy --version 2>/dev/null | head -1)"
log ""
log "Images:"
docker image ls --format '  {{.Repository}}:{{.Tag}} ({{.Size}})' 2>/dev/null | grep -E 'zaproxy|sonarqube|postgres' || log "  (none yet)"
log ""
log "Note: the Jenkinsfile publishes the app on host port 18080, because 8080 is already Jenkins."
