#!/bin/bash
# Verifies composefs + fs-verity related integrity signals for /usr.
set -euo pipefail

QUIET=false
if [[ "${1:-}" == "--quiet" ]]; then
    QUIET=true
fi

log() {
    if [[ "${QUIET}" != true ]]; then
        echo "$1"
    fi
}

fail() {
    echo "$1" >&2
    exit 1
}

if ! command -v findmnt >/dev/null 2>&1; then
    fail "findmnt not available; cannot verify filesystem integrity"
fi

usr_fstype="$(findmnt -n -o FSTYPE /usr 2>/dev/null || true)"
if [[ "${usr_fstype}" != "composefs" ]]; then
    fail "/usr is mounted as '${usr_fstype:-unknown}', expected composefs"
fi

mount_opts="$(findmnt -n -o OPTIONS /usr 2>/dev/null || true)"
if [[ "${mount_opts}" != *"ro"* ]]; then
    fail "/usr is not mounted read-only"
fi

if [[ "${mount_opts}" == *"digest="* || "${mount_opts}" == *"verity"* ]]; then
    log "composefs mount includes digest/verity options"
else
    # Some kernels do not expose digest in mount options. Fall back to module/filesystem checks.
    if [[ ! -d /sys/module/composefs ]] && ! grep -qw "composefs" /proc/filesystems; then
        fail "composefs module/filesystem support not detected"
    fi
    log "composefs active but digest/verity flags not exposed in mount options"
fi

log "Filesystem integrity checks passed"
