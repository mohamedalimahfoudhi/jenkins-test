#!/usr/bin/env bash
#
# scripts/install-tools.sh
# Installs the two Phase 1 pipeline binaries on the Jenkins VM:
#
#   gitleaks  - secrets scanning (CI stage + the local pre-commit hook)
#   hadolint  - Dockerfile linting
#
# Big downloads (this matters on a slow link):
#   hadolint          ~55 MB   <- the large one
#   gitleaks tarball  ~8 MB
#
# Re-runnable and resumable:
#   * an already installed, correct version is skipped (no download at all);
#   * archives stay in CACHE_DIR, so a re-run after a failure reuses a verified
#     archive instead of downloading it again;
#   * a partial archive is continued with curl -C -;
#   * if the server refuses the byte range, or the result fails its checksum,
#     that one file is restarted from zero rather than failing the run.
#
# Integrity: every archive is checked against the sha256 the project publishes
# (gitleaks_<ver>_checksums.txt, hadolint checksums.sha256). If a project stops
# publishing checksums the script warns and continues instead of pretending to
# have verified anything.
#
# Scope: writes only into INSTALL_DIR and CACHE_DIR. It does not touch SSH,
# firewall, proxy or DNS configuration and installs no daemons.
#
# Usage:
#   sudo bash scripts/install-tools.sh
#   INSTALL_DIR="$HOME/.local/bin" bash scripts/install-tools.sh             # no sudo
#   GITLEAKS_VERSION=8.30.1 HADOLINT_VERSION=2.15.1 sudo -E bash scripts/install-tools.sh
#
# Versions default to the current stable releases when this was written.
# Confirm them (each prints the latest tag):
#   curl -sI https://github.com/gitleaks/gitleaks/releases/latest | grep -i location
#   curl -sI https://github.com/hadolint/hadolint/releases/latest  | grep -i location

set -euo pipefail

GITLEAKS_VERSION="${GITLEAKS_VERSION:-8.30.1}"
HADOLINT_VERSION="${HADOLINT_VERSION:-2.15.1}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
CACHE_DIR="${CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/devsecops-tools}"

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

mkdir -p "$INSTALL_DIR" "$CACHE_DIR"
[ -w "$INSTALL_DIR" ] || die "$INSTALL_DIR is not writable. Re-run with sudo, or set INSTALL_DIR=\"\$HOME/.local/bin\""
[ -w "$CACHE_DIR" ]   || die "cache directory not writable: $CACHE_DIR"

# Only extraction is temporary; archives stay in CACHE_DIR so the next run can
# reuse or resume them.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Expected sha256 for a file name, from a "hash  name" / "hash *name" file.
expected_sha256() {
    awk -v n="$2" '{
        hash = $1; fname = $2
        gsub(/^sha256:/, "", hash)
        gsub(/^\*/, "", fname)
        sub(/.*\//, "", fname)
        if (fname == n) { print hash; exit }
    }' "$1"
}

# 0 = file matches its published checksum, 1 = mismatch. No output.
sha256_matches() {
    local file="$1" sums="$2" name="$3" want have
    want="$(expected_sha256 "$sums" "$name")"
    [ -n "$want" ] || return 1
    have="$(sha256sum "$file" | awk '{ print $1 }')"
    [ "$want" = "$have" ]
}

# Download into CACHE_DIR with resume, then verify. Reuses a verified archive.
ensure_archive() {
    local url="$1" dest="$2" sums_url="$3" sums_name="$4" name="$5"
    local have_sums=0

    if curl -fsSL --retry 3 -o "$WORK/$sums_name" "$sums_url"; then
        have_sums=1
    fi

    # A complete, verified archive on disk means no network at all.
    if [ -s "$dest" ] && [ "$have_sums" -eq 1 ] && sha256_matches "$dest" "$WORK/$sums_name" "$name"; then
        log "  cached archive verified, no download needed"
        return 0
    fi

    log "  GET $url"
    if [ -s "$dest" ]; then
        log "  resuming partial download ($(du -h "$dest" | cut -f1) already on disk)"
        if ! curl -fL --retry 3 --retry-delay 3 -C - -o "$dest" "$url"; then
            warn "server refused the resume - restarting $name from zero"
            rm -f "$dest"
            curl -fL --retry 3 --retry-delay 3 -o "$dest" "$url"
        fi
    else
        curl -fL --retry 3 --retry-delay 3 -o "$dest" "$url"
    fi
    [ -s "$dest" ] || die "download failed: $url"

    if [ "$have_sums" -eq 0 ]; then
        warn "no checksum file published for $name - installing unverified"
        return 0
    fi

    if sha256_matches "$dest" "$WORK/$sums_name" "$name"; then
        log "  checksum OK: $name"
        return 0
    fi

    warn "checksum mismatch for $name - restarting that file from zero"
    rm -f "$dest"
    curl -fL --retry 3 --retry-delay 3 -o "$dest" "$url"
    sha256_matches "$dest" "$WORK/$sums_name" "$name" || die "checksum still wrong after full download of $name"
    log "  checksum OK after full download: $name"
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

    ensure_archive "$base/$tarball" "$CACHE_DIR/$tarball" "$base/$sums" "$sums" "$tarball"
    tar xzf "$CACHE_DIR/$tarball" -C "$WORK" gitleaks
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

    ensure_archive "$base/$bin" "$CACHE_DIR/$bin" "$base/$sums" "$sums" "$bin"
    install -m 0755 "$CACHE_DIR/$bin" "$INSTALL_DIR/hadolint"
    log "  installed $INSTALL_DIR/hadolint"
}

log "Installing pipeline tools into $INSTALL_DIR"
log "Download cache: $CACHE_DIR"
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
log "Archives stay in $CACHE_DIR (safe to delete after installing)."
