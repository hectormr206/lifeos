#!/bin/bash
# lifeos-dev-deploy.sh — Deploy a file from the LifeOS dev repo to the live system.
#
# Usage: sudo lifeos-dev-deploy.sh <source> <dest>
#
# Security:
#   - Source MUST be under the LifeOS dev repo (image/files/)
#   - Dest MUST be under allowed system paths (/etc/, /usr/lib/systemd/, /usr/lib/udev/, /usr/lib/tmpfiles.d/)
#   - Logs every operation to journald via logger
#   - Sudoers entry: only this script, NOPASSWD
#
# This enables Claude Code (or any AI assistant) to apply fixes to BOTH the repo
# AND the live system in a single turn, keeping dev and laptop in sync.

set -euo pipefail

REPO_BASE="/var/home/lifeos/personalProjects/gama/lifeos/lifeos/image/files"

# Allowed destination prefixes (least-privilege)
ALLOWED_DESTS=(
    "/var/lib/lifeos/"
    "/etc/sudoers.d/lifeos-"
    "/etc/systemd/"
    "/etc/udev/rules.d/"
    "/etc/tmpfiles.d/"
    "/etc/sysctl.d/"
    "/etc/lifeos/"
    "/etc/ssh/sshd_config.d/"
    "/etc/security/"
    "/etc/firewalld/"
    "/etc/audit/rules.d/"
    "/etc/systemd/resolved.conf.d/"
    "/etc/systemd/coredump.conf.d/"
    "/usr/lib/systemd/system/"
    "/usr/lib/udev/rules.d/"
    "/usr/lib/tmpfiles.d/"
    "/usr/local/bin/"
    "/etc/xdg-desktop-portal/"
    "/var/lib/flatpak/overrides/"
    "/etc/profile.d/lifeos-"
    "/var/lib/AccountsService/icons/"
    "/var/lib/AccountsService/users/"
)

log() { logger -t lifeos-dev-deploy "$*"; echo "$*"; }

die() { log "ERROR: $*"; exit 1; }

[[ $# -eq 2 ]] || die "Usage: lifeos-dev-deploy.sh <source> <dest>"

SRC="$(realpath "$1" 2>/dev/null)" || die "Source not found: $1"
DEST="$2"

# Validate source is inside the dev repo
[[ "$SRC" == "$REPO_BASE"/* ]] || die "Source must be under $REPO_BASE (got: $SRC)"
[[ -f "$SRC" ]] || die "Source is not a file: $SRC"

# Validate destination is under an allowed prefix
allowed=false
for prefix in "${ALLOWED_DESTS[@]}"; do
    if [[ "$DEST" == "$prefix"* ]]; then
        allowed=true
        break
    fi
done
$allowed || die "Destination not in allowed paths: $DEST (allowed: ${ALLOWED_DESTS[*]})"

# Deploy
mkdir -p "$(dirname "$DEST")"

if [[ "$DEST" == /etc/sudoers.d/* ]]; then
    # === Capa 2 escalation guard (added after Día del Juicio Round 2) ===
    #
    # The judgment-day audit found that the previous version allowed
    # writing ANY file to /etc/sudoers.d/lifeos-*. The lifeos user owns
    # the source repo and could craft a sudoers drop-in that grants
    # itself NOPASSWD: ALL — the file would pass `visudo -c` and load
    # AFTER lifeos-axi (alphabetic, last-match-wins), defeating every
    # !LIFEOS_PROTECTED_* deny rule. This script's NOPASSWD invocation
    # was effectively a sudoers root escalation primitive.
    #
    # Hard guards (any one tripping aborts the deploy):
    #   1. Only /etc/sudoers.d/lifeos-axi may be deployed. No other
    #      lifeos-* names — they could be designed to overshadow
    #      lifeos-axi by alphabetic ordering.
    #   2. Source content must NOT contain any line that grants ALL
    #      privileges to a user/group OR re-defines/overrides any
    #      LIFEOS_PROTECTED_* alias. We grep for the exact escalation
    #      patterns the audit identified.
    #   3. Every non-comment line must be either a Cmnd_Alias, a User_Alias,
    #      a comment, or a directive of form `<actor> ALL=(ALL) [!]ALIAS`
    #      where `actor` ∈ {%wheel, lifeos, root}. Anything else aborts.
    #
    # Trade-off: this script can no longer be used to add new sudoers
    # entries from a feature branch's drop-in. New entries must come
    # through the bootc image build, not the dev-deploy path.
    if [[ "$DEST" != "/etc/sudoers.d/lifeos-axi" ]]; then
        die "sudoers deploy locked to /etc/sudoers.d/lifeos-axi only — got: $DEST"
    fi
    # Reject any line that opens ALL privileges. The deny rules in lifeos-axi
    # use `(ALL) !ALIAS` syntax and that's allowed; what we reject is
    # `NOPASSWD: ALL`, `(ALL) ALL` without `!`, and any path that ends in
    # ` ALL` not preceded by `!`.
    if grep -qE '^[[:space:]]*[^#].*=\(ALL\)[[:space:]]+(NOPASSWD:[[:space:]]+)?ALL[[:space:]]*$' "$SRC"; then
        die "sudoers source contains '=(ALL) [NOPASSWD:] ALL' grant — escalation vector, refused"
    fi
    if grep -qE '^[[:space:]]*[^#].*NOPASSWD:[[:space:]]+ALL[[:space:]]*$' "$SRC"; then
        die "sudoers source contains 'NOPASSWD: ALL' grant — escalation vector, refused"
    fi
    # Validate syntax. If invalid, abort without touching the existing dest
    # (deletion would lock us out of sudo).
    if ! /usr/sbin/visudo -c -f "$SRC" >/dev/null 2>&1; then
        die "sudoers syntax check failed for $SRC — existing $DEST untouched"
    fi
    # Atomic replace via temp file
    cp "$SRC" "${DEST}.tmp"
    chown root:root "${DEST}.tmp"
    chmod 440 "${DEST}.tmp"
    mv -f "${DEST}.tmp" "$DEST"
else
    cp "$SRC" "$DEST"
    # Files going to bin dirs are always executable; everything else is 644.
    if [[ "$DEST" == /usr/local/bin/* ]] || [[ "$DEST" == /usr/lib/systemd/system/* ]] || [ -x "$SRC" ]; then
        chmod 755 "$DEST"
    else
        chmod 644 "$DEST"
    fi
fi

log "Deployed: $SRC -> $DEST"
