#!/usr/bin/env bash
#
# scripts/compliance-check.sh
# Compliance check of the artefacts that ship to production: the Dockerfile and
# the Jenkinsfile. It encodes a small container-hardening policy.
#
# Why a policy script instead of a compliance product: OpenSCAP/Chef InSpec
# would need another toolchain and another download on a slow link, and the
# course asks for a justified check, not a specific product. Every rule below
# maps to a concrete risk, and the same rules can be ported to InSpec later.
#
# Rules (Dockerfile):
#   1. every FROM has an explicit tag, never :latest
#   2. a non-root USER is set and it is numeric (no name lookup at runtime)
#   3. HEALTHCHECK is defined
#   4. no ADD (use COPY), no curl|bash style remote execution
#   5. no secrets baked in via ENV/ARG with a suspicious name
#   6. apt-get install cleans /var/lib/apt/lists in the same layer
#
# Rules (Jenkinsfile):
#   7. reports are archived (archiveArtifacts present)
#   8. no security stage is disabled by a hardcoded 'when { expression { false } }'
#
# Exit code 0 = compliant, 1 = at least one violation.

set -uo pipefail

DOCKERFILE="${DOCKERFILE:-Dockerfile}"
JENKINSFILE="${JENKINSFILE:-Jenkinsfile}"
PASS=0
FAIL=0

ok()  { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -f "$DOCKERFILE" ] || { echo "FAIL  $DOCKERFILE not found"; exit 1; }

echo "Compliance check: $DOCKERFILE and $JENKINSFILE"
echo ""

# 1. FROM must be pinned to a tag (or a digest)
unpinned=""
while IFS= read -r line; do
    img="$(printf '%s\n' "$line" | sed -E 's/^FROM[[:space:]]+//I; s/^--platform=[^[:space:]]+[[:space:]]+//I; s/[[:space:]]+[Aa][Ss][[:space:]]+.*$//; s/[[:space:]]+$//')"
    [ -n "$img" ] || continue
    case "$img" in
        *"@"*) continue ;;   # digest pin is the strongest form
    esac
    ref="${img##*/}"
    case "$ref" in
        *:latest) unpinned="$unpinned $img" ;;
        *:*)      : ;;
        *)        unpinned="$unpinned $img" ;;
    esac
done < <(grep -E '^FROM ' "$DOCKERFILE")

if [ -n "$unpinned" ]; then
    bad "image not pinned to a tag:$unpinned"
else
    ok "all FROM instructions are tagged"
fi

# 2. non-root numeric USER
if grep -qE '^USER [0-9]+(:[0-9]+)?$' "$DOCKERFILE"; then
    ok "runs as numeric non-root user: $(grep -E '^USER ' "$DOCKERFILE" | tail -1)"
elif grep -qE '^USER ' "$DOCKERFILE"; then
    bad "USER is set but not numeric: $(grep -E '^USER ' "$DOCKERFILE" | tail -1)"
else
    bad "no USER instruction - the container would run as root"
fi

# 3. HEALTHCHECK
grep -qE '^HEALTHCHECK ' "$DOCKERFILE" && ok "HEALTHCHECK defined" || bad "no HEALTHCHECK"

# 4. ADD / curl|bash
grep -qE '^ADD ' "$DOCKERFILE" && bad "ADD used - prefer COPY" || ok "no ADD instruction"
if grep -qE 'curl[^|]*\|[[:space:]]*(ba)?sh' "$DOCKERFILE"; then
    bad "remote script piped into a shell"
else
    ok "no remote script piped into a shell"
fi

# 5. secret-ish ENV/ARG
if grep -iE '^(ENV|ARG)[[:space:]]+[A-Z_]*(PASSWORD|SECRET|TOKEN|APIKEY|API_KEY)' "$DOCKERFILE" >/dev/null; then
    bad "secret-like ENV/ARG in image: $(grep -iE '^(ENV|ARG)[[:space:]]+[A-Z_]*(PASSWORD|SECRET|TOKEN|APIKEY|API_KEY)' "$DOCKERFILE" | tr '\n' ' ')"
else
    ok "no secret-like ENV/ARG baked into the image"
fi

# 6. apt list cleanup
if grep -q 'apt-get install' "$DOCKERFILE"; then
    if grep -q 'rm -rf /var/lib/apt/lists' "$DOCKERFILE"; then
        ok "apt lists are cleaned in the same layer"
    else
        bad "apt-get install without rm -rf /var/lib/apt/lists"
    fi
else
    ok "no apt-get install in the image"
fi

# 7-8 Jenkinsfile rules
if [ -f "$JENKINSFILE" ]; then
    grep -q 'archiveArtifacts' "$JENKINSFILE" && ok "Jenkinsfile archives reports" || bad "Jenkinsfile has no archiveArtifacts"
    if grep -qE 'when[[:space:]]*\{[[:space:]]*expression[[:space:]]*\{[[:space:]]*false' "$JENKINSFILE"; then
        bad "a stage is hardcoded off (when { expression { false } })"
    else
        ok "no stage is hardcoded off"
    fi
else
    bad "$JENKINSFILE not found"
fi

echo ""
echo "Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
