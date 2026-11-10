#!/usr/bin/env bash
#
# scripts/install-dependency-check.sh
# Installs the OWASP Dependency-Check CLI for the Jenkins pipeline and
# pre-downloads its vulnerability database, so the first build does not sit for
# 20+ minutes fetching NVD data in the middle of a stage.
#
# Big downloads:
#   CLI zip (v13.0.0)      ~29 MB
#   NVD database           hundreds of MB, and it is by far the slow part.
#                          Run this over a good connection, once.
#
# Re-runnable: an already extracted CLI of the right version is skipped, the
# zip download resumes (curl -C -), and the database update continues from
# whatever is already cached in $DC_HOME/data.
#
# Integrity: OWASP publishes the CLI zip plus a detached PGP signature
# (dependency-check-<ver>-release.zip.asc) but no .sha256 sidecar, so this
# script pins the SHA-256 that was measured when the version was chosen.
# Override with DC_SHA256=... if you deliberately install another build.
#
# Usage:
#   sudo bash scripts/install-dependency-check.sh
#   sudo NVD_API_KEY=<your key> bash scripts/install-dependency-check.sh   # strongly recommended
#   sudo SKIP_DB_UPDATE=1 bash scripts/install-dependency-check.sh          # CLI only
#
# Never put the NVD API key in this repository or in the Jenkinsfile.

set -euo pipefail

DC_VERSION="${DC_VERSION:-13.0.0}"
DC_HOME="${DC_HOME:-/opt/dependency-check}"
DC_USER="${DC_USER:-jenkins}"
CACHE_DIR="${CACHE_DIR:-/var/cache/devsecops-tools}"
NVD_API_KEY="${NVD_API_KEY:-}"
SKIP_DB_UPDATE="${SKIP_DB_UPDATE:-0}"

# Pinned 2026-11-10 for dependency-check-13.0.0-release.zip.
DC_SHA256="${DC_SHA256:-44d920d1ec03e948df862a253f0912782a31b9beee8a7c8895b9cb95760176ed}"

log()  { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v curl  >/dev/null || die "curl is required"
command -v sha256sum >/dev/null || die "sha256sum is required"
command -v java  >/dev/null || die "java is required (Dependency-Check needs a JDK/JRE 11+)"

AS_ROOT=0
[ "$(id -u)" -eq 0 ] && AS_ROOT=1

ZIP="dependency-check-${DC_VERSION}-release.zip"
URL="https://github.com/dependency-check/DependencyCheck/releases/download/v${DC_VERSION}/${ZIP}"

mkdir -p "$CACHE_DIR" || die "cannot create cache directory $CACHE_DIR"
log "CLI version : $DC_VERSION"
log "Install dir : $DC_HOME"
log "Cache dir   : $CACHE_DIR"
log ""

# ---------- already installed? ----------
if [ -x "$DC_HOME/bin/dependency-check.sh" ] \
   && "$DC_HOME/bin/dependency-check.sh" --version 2>/dev/null | grep -q "$DC_VERSION"; then
    log "Dependency-Check $DC_VERSION already installed at $DC_HOME - skipping download"
else
    # ---------- download (resumable) ----------
    if [ -s "$CACHE_DIR/$ZIP" ] && echo "$DC_SHA256  $CACHE_DIR/$ZIP" | sha256sum -c - >/dev/null 2>&1; then
        log "cached archive verified, no download needed: $ZIP"
    else
        log "downloading $ZIP (~29 MB)"
        if [ -s "$CACHE_DIR/$ZIP" ]; then
            log "resuming partial download ($(du -h "$CACHE_DIR/$ZIP" | cut -f1) on disk)"
            curl -fL --retry 3 --retry-delay 3 -C - -o "$CACHE_DIR/$ZIP" "$URL" \
                || { warn "server refused the resume - restarting from zero"; rm -f "$CACHE_DIR/$ZIP"; curl -fL --retry 3 --retry-delay 3 -o "$CACHE_DIR/$ZIP" "$URL"; }
        else
            curl -fL --retry 3 --retry-delay 3 -o "$CACHE_DIR/$ZIP" "$URL"
        fi
        [ -s "$CACHE_DIR/$ZIP" ] || die "download failed: $URL"
    fi

    echo "$DC_SHA256  $CACHE_DIR/$ZIP" | sha256sum -c - >/dev/null 2>&1 \
        || die "checksum mismatch for $ZIP (expected $DC_SHA256)"
    log "checksum OK: $ZIP"

    # ---------- extract ----------
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    if command -v unzip >/dev/null; then
        unzip -q "$CACHE_DIR/$ZIP" -d "$TMP"
    else
        warn "unzip not installed - falling back to python3 zipfile"
        python3 -m zipfile -e "$CACHE_DIR/$ZIP" "$TMP"
    fi
    [ -x "$TMP/dependency-check/bin/dependency-check.sh" ] || die "unexpected archive layout: bin/dependency-check.sh missing"
    mkdir -p "$DC_HOME"
    cp -a "$TMP/dependency-check/." "$DC_HOME/"
    log "extracted to $DC_HOME"
fi

chmod +x "$DC_HOME/bin/dependency-check.sh"
mkdir -p "$DC_HOME/data"

# ---------- ownership ----------
if [ "$AS_ROOT" -eq 1 ]; then
    id -u "$DC_USER" >/dev/null 2>&1 || die "user '$DC_USER' does not exist (set DC_USER=...)"
    chown -R "$DC_USER:$DC_USER" "$DC_HOME"
    chmod -R u+rwX "$DC_HOME/data"
    log "ownership: $DC_USER"
else
    warn "not running as root - skipping chown. Ensure $DC_HOME is owned by the Jenkins user."
fi

# ---------- pre-download the vulnerability database ----------
if [ "$SKIP_DB_UPDATE" = "1" ]; then
    log "SKIP_DB_UPDATE=1 - database download skipped"
elif [ -n "$(ls -A "$DC_HOME/data" 2>/dev/null)" ]; then
    log "database cache already present in $DC_HOME/data - running an incremental update"
else
    log ""
    log "Pre-downloading the NVD database (the slow part: hundreds of MB)."
    [ -n "$NVD_API_KEY" ] || warn "no NVD_API_KEY given - this can take a very long time (the CLI is rate-limited without a key)"
fi

if [ "$SKIP_DB_UPDATE" != "1" ]; then
    UPDATE_CMD=("$DC_HOME/bin/dependency-check.sh" --updateonly --data "$DC_HOME/data")
    [ -n "$NVD_API_KEY" ] && UPDATE_CMD+=(--nvdApiKey "$NVD_API_KEY")

    if [ "$AS_ROOT" -eq 1 ]; then
        sudo -u "$DC_USER" bash -c "$(printf '%q ' "${UPDATE_CMD[@]}")" \
            || die "database update failed - re-run to continue from cached data (if it looks like an environment problem: sudo -u jenkins java -version)"
    else
        "${UPDATE_CMD[@]}" || die "database update failed - re-run to continue from cached data (if it looks like an environment problem: sudo -u jenkins java -version)"
    fi
fi

# ---------- result ----------
log ""
log "Dependency-Check version: $("$DC_HOME/bin/dependency-check.sh" --version 2>/dev/null | tail -1)"
log "Data directory: $DC_HOME/data ($(du -sh "$DC_HOME/data" 2>/dev/null | cut -f1))"
log ""
log "Next: register this installation in Jenkins"
log "  Manage Jenkins > Tools > Dependency-Check installations"
log "    Name: dependency-check      <- must match odcInstallation in the Jenkinsfile"
log "    Path: $DC_HOME"
log "  (the Jenkinsfile's dependencyCheck step uses additionalArguments for the rest)"
