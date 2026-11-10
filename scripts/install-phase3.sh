#!/usr/bin/env bash
#
# scripts/install-phase3.sh
# Phase 3 (Production) host hardening for the Jenkins VM:
#   * fail2ban   - host intrusion detection for SSH (sshd jail)
#   * ufw        - host firewall, ordered so SSH is allowed BEFORE it is enabled
#   * unattended-upgrades - security patches applied automatically
#
# It deliberately does NOT touch /etc/ssh/sshd_config. Changing the SSH daemon
# from a script that runs over SSH is how people lock themselves out; if you
# want to disable root login or passwords, do it by hand and keep a second
# session open while you test it.
#
# Idempotent: packages are installed by apt (no-op if present), the jail file
# and the auto-upgrade file are rewritten with the same content, `ufw allow`
# skips existing rules, and services are only enabled/restarted.
#
# DRY_RUN=1 prints every command and the file contents without changing
# anything - useful to review the order before you run it for real.
#
# Usage:
#   sudo bash scripts/install-phase3.sh
#   DRY_RUN=1 bash scripts/install-phase3.sh          # review only, no root needed
#   sudo SSH_PORT=2222 bash scripts/install-phase3.sh # non-default SSH port
#
# Safety: if nothing is listening on SSH_PORT, the script stops BEFORE enabling
# ufw, because enabling a default-deny firewall without an SSH rule is an
# instant lockout.

set -euo pipefail

SSH_PORT="${SSH_PORT:-22}"
JENKINS_PORT="${JENKINS_PORT:-8080}"
APP_PORT="${APP_PORT:-18080}"
PROD_PORT="${PROD_PORT:-18081}"
DRY_RUN="${DRY_RUN:-0}"

# 10.0.2.2 is the host side of the VirtualBox/Vagrant NAT network: `vagrant ssh`
# and host-forwarded connections appear to come from it. Keeping it in
# ignoreip means your own sessions can never be banned, even after repeated
# typo'd passwords.
FAIL2BAN_IGNOREIP="${FAIL2BAN_IGNOREIP:-127.0.0.1/8 ::1 10.0.2.2}"

JAIL_FILE="/etc/fail2ban/jail.d/devsecops.local"
AUTO_UPGRADES_FILE="/etc/apt/apt.conf.d/20auto-upgrades"

log()  { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

run() {
    if [ "$DRY_RUN" = "1" ]; then
        printf 'DRY-RUN: %s\n' "$*"
    else
        "$@"
    fi
}

write_config() {
    local path="$1" content="$2"
    if [ "$DRY_RUN" = "1" ]; then
        printf 'DRY-RUN: would write %s with:\n------------------------\n%s\n------------------------\n' "$path" "$content"
    else
        printf '%s\n' "$content" > "$path"
    fi
}

if [ "$DRY_RUN" != "1" ]; then
    [ "$(id -u)" -eq 0 ] || die "run as root: sudo bash scripts/install-phase3.sh"
fi

log "Phase 3 hardening (dry run: $DRY_RUN)"
log "  SSH port      : $SSH_PORT"
log "  Jenkins port  : $JENKINS_PORT"
log "  App port      : $APP_PORT (acceptance container)"
log "  Prod port     : $PROD_PORT (production container)"
log "  fail2ban ignore: $FAIL2BAN_IGNOREIP"
log ""

# ------------------------------------------------------------- packages ------
log "Installing fail2ban, ufw and unattended-upgrades"
run apt-get update -qq
run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fail2ban ufw unattended-upgrades

# -------------------------------------------------------------- fail2ban -----
log "Writing the sshd jail to $JAIL_FILE"
write_config "$JAIL_FILE" "[DEFAULT]
# Never ban our own access paths: loopback and the Vagrant/VirtualBox NAT host.
ignoreip = ${FAIL2BAN_IGNOREIP}
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port    = ${SSH_PORT}"

if [ "$DRY_RUN" != "1" ]; then
    log "Validating the fail2ban configuration"
    fail2ban-client -t || die "fail2ban configuration is invalid, nothing was restarted"
fi

run systemctl enable fail2ban
run systemctl restart fail2ban

# -------------------------------------------------------------------- ufw ----
log ""
log "Configuring ufw: allow SSH FIRST, enable the firewall LAST"
run ufw default deny incoming
run ufw default allow outgoing
run ufw allow "${SSH_PORT}/tcp" comment 'SSH - must exist before ufw is enabled'
run ufw allow "${JENKINS_PORT}/tcp" comment 'Jenkins'
run ufw allow "${APP_PORT}/tcp" comment 'application (acceptance)'

if [ "$DRY_RUN" = "1" ]; then
    log "DRY-RUN: would verify that something is listening on port ${SSH_PORT} before enabling ufw"
    log "DRY-RUN: ufw --force enable"
else
    # The lockout guard: no listener on SSH means enabling the firewall would
    # cut the connection that is running this script.
    if command -v ss >/dev/null 2>&1 && ! ss -ltn | grep -q ":${SSH_PORT} "; then
        die "nothing is listening on port ${SSH_PORT} - refusing to enable ufw (this would lock you out)"
    fi
    if ! ufw show added | grep -qE "allow ${SSH_PORT}/tcp"; then
        die "the SSH allow rule is not present - refusing to enable ufw"
    fi
    ufw --force enable
fi

# --------------------------------------------------- unattended-upgrades -----
log ""
log "Enabling automatic security updates ($AUTO_UPGRADES_FILE)"
write_config "$AUTO_UPGRADES_FILE" 'APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";'
run systemctl enable unattended-upgrades
run systemctl restart unattended-upgrades

# ------------------------------------------------------------ verification ---
log ""
log "Current state"
if [ "$DRY_RUN" = "1" ]; then
    log "  (dry run - nothing was changed)"
else
    log "  --- fail2ban ---"
    fail2ban-client status sshd 2>/dev/null || warn "sshd jail not reported yet (check: systemctl status fail2ban)"
    log "  --- ufw ---"
    ufw status verbose
    log "  --- unattended-upgrades ---"
    systemctl is-active unattended-upgrades || true
    apt-config dump APT::Periodic::Unattended-Upgrade || true
fi

log ""
log "Done. Your SSH session was never at risk: the SSH rule is added before ufw is enabled,"
log "and 10.0.2.2 is in fail2ban ignoreip so vagrant ssh cannot be banned."
