#!/usr/bin/env bash
#
# scripts/infra-check.sh
# Infrastructure test of the Jenkins VM, run as a pipeline stage.
#
# Why a shell script and not InSpec: InSpec needs Ruby and a gem install, which
# on this VM means another few hundred MB over a slow link and a second
# configuration language for the report. The checks below are the same
# assertions InSpec would make for this exercise, in one dependency-free file.
# If the course requires a real compliance framework, this script is a drop-in
# list of controls to port.
#
# Exit code 0 = all infrastructure expectations hold, 1 = at least one failed.
#
# Usage:
#   bash scripts/infra-check.sh
#   MIN_DISK_GB=5 MIN_RAM_MB=3500 bash scripts/infra-check.sh

set -uo pipefail

MIN_DISK_GB="${MIN_DISK_GB:-3}"
MIN_RAM_MB="${MIN_RAM_MB:-3000}"
PASS=0
FAIL=0

ok()   { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }
info() { printf 'INFO  %s\n' "$1"; }

echo "Infrastructure check on $(hostname)"
echo ""

# OS
if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    info "OS: ${PRETTY_NAME:-unknown}"
    case "${ID:-}:${VERSION_ID:-}" in
        ubuntu:22.04) ok "operating system is Ubuntu 22.04" ;;
        *) bad "expected Ubuntu 22.04, found ${ID:-?} ${VERSION_ID:-?}" ;;
    esac
else
    bad "/etc/os-release missing"
fi

# CPU / RAM
cpus="$(nproc)"
[ "$cpus" -ge 2 ] && ok "CPU cores: $cpus (>= 2)" || bad "CPU cores: $cpus (< 2)"

ram_mb="$(awk '/MemTotal/ { printf "%d", $2/1024 }' /proc/meminfo)"
[ "$ram_mb" -ge "$MIN_RAM_MB" ] && ok "RAM: ${ram_mb} MB (>= $MIN_RAM_MB)" || bad "RAM: ${ram_mb} MB (< $MIN_RAM_MB)"

# Swap (headroom for the heavy scanners)
swap_mb="$(awk '/SwapTotal/ { printf "%d", $2/1024 }' /proc/meminfo)"
[ "$swap_mb" -gt 0 ] && ok "swap configured: ${swap_mb} MB" || bad "no swap configured (see scripts/add-swap.sh)"

# Disk
disk_gb="$(df -Pk / | awk 'NR==2 { printf "%d", $4/1024/1024 }')"
[ "$disk_gb" -ge "$MIN_DISK_GB" ] && ok "free disk on /: ${disk_gb} GB (>= $MIN_DISK_GB)" || bad "free disk on /: ${disk_gb} GB (< $MIN_DISK_GB)"

# Java (Jenkins tool) and Maven
if command -v java >/dev/null 2>&1; then
    java_major="$(java -version 2>&1 | awk -F'"' '/version/ { print $2 }' | cut -d. -f1)"
    [ "${java_major:-0}" -ge 17 ] && ok "java $java_major on PATH (>= 17)" || bad "java ${java_major:-?} on PATH (< 17)"
else
    bad "java not on PATH"
fi
command -v mvn >/dev/null 2>&1 && ok "maven on PATH" || info "maven not on PATH for this user (Jenkins provides it via the maven tool)"

# Docker
if command -v docker >/dev/null 2>&1; then
    ok "docker CLI present: $(docker --version | cut -d, -f1)"
    if docker info >/dev/null 2>&1; then
        ok "docker daemon reachable by $(id -un)"
    else
        info "docker daemon not reachable by $(id -un) (expected unless you are jenkins or in the docker group)"
    fi
else
    bad "docker CLI not installed (run scripts/install-phase2.sh)"
fi

# Trivy
if command -v trivy >/dev/null 2>&1; then
    ok "trivy present: $(trivy --version | head -1)"
else
    bad "trivy not installed (run scripts/install-phase2.sh)"
fi

# Gitleaks / hadolint (Phase 1)
for bin in gitleaks hadolint; do
    command -v "$bin" >/dev/null 2>&1 && ok "$bin on PATH" || bad "$bin missing (run scripts/install-tools.sh)"
done

# Dependency-Check CLI (Phase 1)
DC_HOME="${DC_HOME:-/opt/dependency-check}"
[ -x "$DC_HOME/bin/dependency-check.sh" ] && ok "Dependency-Check CLI at $DC_HOME" || bad "Dependency-Check CLI missing at $DC_HOME"

# Listening ports that matter
if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -q ':8080 ' && ok "port 8080 (Jenkins) is listening" || bad "port 8080 (Jenkins) is not listening"
fi

echo ""
echo "Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
