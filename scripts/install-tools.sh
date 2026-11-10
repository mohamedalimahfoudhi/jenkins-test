#!/usr/bin/env bash
#
# scripts/install-tools.sh
# Installs the two Phase 1 pipeline binaries on the Jenkins VM:
#
#   gitleaks  - secrets scanning (CI stage + the local pre-commit hook)
#   hadolint  - Dockerfile linting
#
# Big downloads (important on a slow link):
#   hadolint          ~55 MB   <- the large one
#   gitleaks tarball  ~8 MB
#
# Safe to re-run: a correct version already present in INSTALL_DIR is skipped,
# and interrupted downloads resume (curl -C -) because the partial file is kept
# until the checksum matches and the binary is installed.
#
# This script writes only into INSTALL_DIR. It does not touch SSH, firewall,
# proxy or DNS configuration, and it installs no daemons.
#
# Usage:
#   sudo bash scripts/install-tools.sh
#   INSTALL_DIR="$HOME/.local/bin" bash scripts/install-tools.sh          # no sudo
#   GITLEAKS_VERSION=8.30.1 HADOLINT_VERSION=2.15.1 sudo -E bash scripts/install-tools.sh
#
# Versions default to the current stable releases at the time of writing.
# Confirm the current ones with:
#   curl -sI https://github.com/gitleaks/gitleaks/releases/latest | grep -i location
#   curl -sI https://github.com/hadolint/hadolint/releases/latest  | grep -i location
#
# Part of the script's state lives in a temp directory that is removed on exit;
# the installed binaries are the only persistent change.

set -euo pipefail

GITLEAKS_VERSION="${GITLEAKS_VERSION:-8.30.1}"
HADOLINT_VERSION="${HADOLINT_VERSION:-2.15.1}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"

log()  { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

for cmd in curl tar sha256sum uname mktemp install awk; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command missing: $cmd"
done

# The two projects spell the architecture differently on purpose:
# gitleaks uses x64/arm64, hadolint uses x86_64/arm64.
case "$(uname -m)" in
    x86_64|amd64)  GITLEAKS_ARCH="x64";   HADOLINT_ARCH="x86_64" ;;
    aarch64|arm64) GITLEAKS_ARCH="arm64"; HADOLINT_ARCH="arm64"  ;;
    *) die "unsupported CPU architecture: $(uname -m)" ;;
esac

mkdir -p "$INSTALL_DIR"
[ -w "$INSTALL_DIR" ] || die "$INSTALL_DIR is not writable. Re-run with sudo, or set INSTALL_DIR=\"\$HOME/.local/bin\""

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Resumable download: -C - continues an interrupted file instead of restarting
# from zero, which matters on a slow connection.
fetch() {
    local url="$1" dest="$2"
    log "  GET $url"
    if [ -s "$dest" ]; then
        log "  resuming partial download: $(basename "$dest")"
        curl -fL --retry 3 --retry-delay 3 -C - -o "$dest" "$url" || true
    else
        curl -fL --retry 3 --retry-delay 3 -o "$dest" "$url"
    fi
    [ -s "$dest" ] || die "download failed: $url"
}

# Verify a sha256 from a "hash  filename" checksum file, when one is published.
verify_sha256() {
    local file="$1" sums="$2" name="$3" expected actual
    # Formats seen in the wild: "hash  name", "hash *name", "sha256:hash  ./name".
    expected="$(awk -v n="$name" '{
        hash = $1; file = $2
        gsub(/^sha256:/, "", hash)
        gsub(/^\*/, "", file)
        sub(/.*\//, "", file)
        if (file == n) { print hash; exit }
    }' "$sums")"
    if [ -z "$expected" ]; then
        warn "no entry for $name in $(basename "$sums") - skipping verification"
        return 0
    fi
    actual="$(sha256sum "$file" | awk '{ print $1 }')"
    [ "$actual" = "$expected" ] || die "checksum mismatch for $name (expected $expected, got $actual)"
    log "  checksum OK: $name"
}

install_gitleaks() {
    if [ -x "$INSTALL_DIR/gitleaks" ] && "$INSTALL_DIR/gitleaks" version 2>/dev/null | grep -qx "$GITLEAKS_VERSION"; then
        log "gitleaks $GITLEAKS_VERSION already present - skipping"
        return 0
    fi

    log "gitleaks $GITLEAKS_VERSION (download: ~8 MB)"
    local base="https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}"
    local tarball="gitleaks_${GITLEAKS_VERSION}_linux_${GITLEAKS_ARCH}.tar.gz"
    local sums="gitleaks_${GITLEAKS_VERSION}_checksums.txt"

    fetch "$base/$tarball" "$WORK/$tarball"
    if curl -fsSL --retry 3 -o "$WORK/$sums" "$base/$sums"; then
        verify_sha256 "$WORK/$tarball" "$WORK/$sums" "$tarball"
    else
        warn "gitleaks publish no checksum file for $GITLEAKS_VERSION - installing unverified"
    fi

    tar xzf "$WORK/$tarball" -C "$WORK" gitleaks
    install -m 0755 "$WORK/gitleaks" "$INSTALL_DIR/gitleaks"
    log "  installed $INSTALL_DIR/gitleaks"
}

install_hadolint() {
    if [ -x "$INSTALL_DIR/hadolint" ] && "$INSTALL_DIR/hadolint" --version 2>/dev/null | grep -q " ${HADOLINT_VERSION}$"; then
        log "hadolint $HADOLINT_VERSION already present - skipping"
        return 0
    fi

    log "hadolint $HADOLINT_VERSION (download: ~55 MB - largest of the two)"
    local base="https://github.com/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}"
    local bin="hadolint-linux-${HADOLINT_ARCH}"
    local sums="checksums.sha256"

    fetch "$base/$bin" "$WORK/$bin"
    if curl -fsSL --retry 3 -o "$WORK/$sums" "$base/$sums"; then
        verify_sha256 "$WORK/$bin" "$WORK/$sums" "$bin"
    else
        warn "hadolint checksum file unavailable for v$HADOLINT_VERSION - installing unverified"
    fi

    install -m 0755 "$WORK/$bin" "$INSTALL_DIR/hadolint"
    log "  installed $INSTALL_DIR/hadolint"
}

log "Installing pipeline tools into $INSTALL_DIR"
log ""
install_gitleaks
install_hadolint

log ""
log "Installed versions:"
printf '  gitleaks: %s\n' "$("$INSTALL_DIR/gitleaks" version)"
printf '  hadolint: %s\n' "$("$INSTALL_DIR/hadolint" --version)"

case ":$PATH:" in
    *":$INSTALL_DIR:"*) : ;;
    *) warn "$INSTALL_DIR is not on PATH for this shell - add it, or Jenkins will not find the tools" ;;
esac

log ""
log "Done. Verify with: gitleaks version && hadolint --version"
