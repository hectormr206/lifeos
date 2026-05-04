#!/bin/bash
# LifeOS state migration — copies ~/.local/share/lifeos/* to /var/lib/lifeos/
# the first time the lifeos-lifeosd Quadlet runs on a host that previously
# ran the user-scope lifeosd binary. Idempotent: noop if /var/lib/lifeos
# already has memory.db.
#
# The encrypted memory.db key derives from /etc/machine-id + /etc/hostname
# (daemon/src/memory_plane.rs::derive_machine_key). The Quadlet bind-mounts
# both files into the container so the key resolves identically pre/post
# migration. We do NOT copy /etc/machine-id — that lives forever where
# systemd put it. We DO copy the user's data directory.
#
# Source-of-truth host user — hard-coded to `lifeos` (the LifeOS daemon's
# canonical user). If a future LifeOS supports multi-user, this script
# becomes a per-user oneshot.
set -euo pipefail

HOST_USER="lifeos"
SRC="/home/${HOST_USER}/.local/share/lifeos"
DST="/var/lib/lifeos"

log() { logger -t lifeos-state-migrate "$*"; printf "[lifeos-state-migrate] %s\n" "$*"; }

# Already migrated? Then there is no work to do.
if [[ -f "${DST}/memory.db" ]]; then
    log "memory.db already at ${DST} — migration noop"
    exit 0
fi

# Source missing? Then there's nothing to migrate (fresh install).
if [[ ! -d "$SRC" ]]; then
    log "no ${SRC} on host — nothing to migrate (fresh install)"
    exit 0
fi

if [[ ! -f "${SRC}/memory.db" ]]; then
    log "no ${SRC}/memory.db — nothing to migrate"
    exit 0
fi

log "migrating ${SRC} → ${DST} (preserving ownership and SELinux context)"

# cp -a preserves perms, ownership, timestamps, xattrs (SELinux contexts).
# We use a temp dir + atomic rename so a crash mid-copy doesn't leave a
# half-populated /var/lib/lifeos.
TMP="${DST}.migrate.$$"
mkdir -p "$TMP"
if ! cp -a "${SRC}/." "${TMP}/"; then
    rm -rf "$TMP"
    log "ERROR: cp failed — check disk space and SELinux"
    exit 1
fi

# Atomic swap: rename old empty /var/lib/lifeos out, rename TMP in.
if [[ -d "$DST" ]]; then
    mv "$DST" "${DST}.empty.$$" || true
fi
mv "$TMP" "$DST"
rm -rf "${DST}.empty.$$" 2>/dev/null || true

# Sanity: assert memory.db and the perms we expect.
if [[ -f "${DST}/memory.db" ]]; then
    log "migration complete: $(du -sh "$DST" | cut -f1) at $DST"
    log "first reboot of lifeos-lifeosd Quadlet will read this DB with the same /etc/machine-id key."
    exit 0
else
    log "ERROR: memory.db missing post-migration — restoring backup if possible"
    exit 1
fi
