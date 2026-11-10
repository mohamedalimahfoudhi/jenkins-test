#!/usr/bin/env bash
#
# scripts/add-swap.sh
# Optional: adds a 2 GB swap file to the Jenkins VM. This is not required for
# the pipeline; it buys headroom on a 4 GB box when Dependency-Check and
# SonarQube run in the same hour.
#
# Idempotent: if the swap file is already active, nothing is done. Exits 0 in
# that case so it can be re-run safely.
# It does NOT change vm.swappiness, SSH, firewall or any other system setting.
#
# Usage:
#   sudo bash scripts/add-swap.sh
#   sudo SWAP_SIZE=2G SWAP_FILE=/swapfile bash scripts/add-swap.sh
#
# Undo (only if you really want to remove it):
#   sudo swapoff /swapfile && sudo rm /swapfile
#   then delete the line containing "/swapfile" from /etc/fstab

set -euo pipefail

SWAP_FILE="${SWAP_FILE:-/swapfile}"
SWAP_SIZE="${SWAP_SIZE:-2G}"

log()  { printf '%s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root: sudo bash scripts/add-swap.sh"
command -v mkswap >/dev/null || die "mkswap not available (package util-linux missing)"
command -v fallocate >/dev/null || die "fallocate not available (package util-linux missing)"

if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$SWAP_FILE"; then
    log "swap already active: $SWAP_FILE"
    swapon --show
    exit 0
fi

if [ -e "$SWAP_FILE" ]; then
    log "swap file exists but is not active, activating it: $SWAP_FILE"
else
    log "creating $SWAP_SIZE swap file at $SWAP_FILE"
    if ! fallocate -l "$SWAP_SIZE" "$SWAP_FILE" 2>/dev/null; then
        log "fallocate refused (filesystem may not support it) - using dd instead"
        dd if=/dev/zero of="$SWAP_FILE" bs=1M count=2048 status=progress
    fi
    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE"
fi

chmod 600 "$SWAP_FILE"

# fstab entry is what makes it survive a reboot; add it once.
if grep -qE "^[[:space:]]*${SWAP_FILE}[[:space:]]" /etc/fstab; then
    log "fstab already references $SWAP_FILE"
else
    printf '%s none swap sw 0 0\n' "$SWAP_FILE" >> /etc/fstab
    log "added $SWAP_FILE to /etc/fstab"
fi

swapon "$SWAP_FILE"
log ""
log "Swap now:"
swapon --show
log ""
free -h
