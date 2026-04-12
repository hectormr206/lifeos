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
cp "$SRC" "$DEST"
# Preserve executable bit from source; default to 644 for configs
if [ -x "$SRC" ]; then
    chmod 755 "$DEST"
else
    chmod 644 "$DEST"
fi

log "Deployed: $SRC -> $DEST"
