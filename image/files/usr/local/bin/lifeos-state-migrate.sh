#!/bin/bash
# LifeOS state migration — copies the daemon's own state files from the
# legacy user-scope home (~/.local/share/lifeos) to the system-scope
# /var/lib/lifeos that the lifeos-lifeosd Quadlet bind-mounts.
#
# The encrypted memory.db key derives from /etc/machine-id + /etc/hostname
# (daemon/src/memory_plane.rs::derive_machine_key). The Quadlet bind-mounts
# both files into the container so the key resolves identically pre/post
# migration. We do NOT touch /etc/machine-id.
#
# Round-1 audit (Día del Juicio post-Phase-3) flagged the previous
# wholesale `mv $DST $DST.empty + rm -rf` strategy as DESTRUCTIVE: it
# wiped /var/lib/lifeos/n (GitHub Actions runner state, registration token,
# work tree) and /var/lib/lifeos/simplex (the SimpleX bot's contact DB and
# encrypted vault). We now MERGE the daemon-owned files INTO an existing
# /var/lib/lifeos, leaving sibling subtrees alone:
#
#   - memory.db  + memory.db-shm/-wal  (encrypted SQLite memory store)
#   - session_store.db                 (per-channel chat session state)
#   - calendar.db                      (Axi calendar store)
#   - scheduled_tasks.db               (scheduler queue)
#   - voices/                          (Kokoro voice cache, optional)
#
# Anything not in the explicit list is left in $SRC. Future state files
# the daemon adds need a line here (it is small and audit-able).
#
# Idempotent: noop if the file already exists at $DST. Safe to re-run.
set -euo pipefail

# Resolve the primary user's home directory dynamically. LifeOS bootc deploys
# default to UID 1000 named `lifeos` but the username varies (operator picks
# during first boot, or imports an existing one). `getent passwd 1000` gives
# us the home dir without hardcoding the name.
PRIMARY_PWENT="$(getent passwd 1000 || true)"
PRIMARY_HOME="$(printf '%s' "$PRIMARY_PWENT" | awk -F: '{print $6}')"
if [[ -z "$PRIMARY_HOME" || ! -d "$PRIMARY_HOME" ]]; then
    logger -t lifeos-state-migrate "no UID-1000 home detected — nothing to migrate"
    exit 0
fi
SRC="${PRIMARY_HOME}/.local/share/lifeos"
DST="/var/lib/lifeos"

log() { logger -t lifeos-state-migrate "$*"; printf "[lifeos-state-migrate] %s\n" "$*"; }

# Bail out cleanly when there is nothing to do.
if [[ ! -d "$SRC" ]]; then
    log "no ${SRC} on host — nothing to migrate (fresh install)"
    exit 0
fi
if [[ -f "${DST}/memory.db" ]]; then
    log "${DST}/memory.db already present — migration noop"
    exit 0
fi
if [[ ! -f "${SRC}/memory.db" ]]; then
    log "no ${SRC}/memory.db — nothing to migrate"
    exit 0
fi

# Files (relative to $SRC) that the daemon owns. Order doesn't matter —
# each is copied independently, missing entries are skipped.
DAEMON_FILES=(
    memory.db
    memory.db-shm
    memory.db-wal
    session_store.db
    session_store.db-shm
    session_store.db-wal
    calendar.db
    calendar.db-shm
    calendar.db-wal
    scheduled_tasks.db
    scheduled_tasks.db-shm
    scheduled_tasks.db-wal
)
DAEMON_DIRS=(
    voices
)

mkdir -p "$DST"
copied=0
skipped=0

# `cp -a` preserves perms, ownership, timestamps, and (on SELinux systems)
# tries to copy `security.selinux` xattrs. If the source xattr is
# user_home_t and the destination filesystem rejects it under var_lib_t
# enforcement, cp drops the xattr; the Quadlet's `:z` mount then relabels
# the target on first container start. We invoke `restorecon` at the end
# to normalize for any host-side consumer that runs in between.
for f in "${DAEMON_FILES[@]}"; do
    if [[ -f "${SRC}/${f}" ]]; then
        if cp -a "${SRC}/${f}" "${DST}/${f}"; then
            copied=$((copied + 1))
        else
            log "ERROR: failed to copy ${f} — leaving migration partial; daemon will use the existing files at ${DST}/."
            exit 1
        fi
    else
        skipped=$((skipped + 1))
    fi
done

for d in "${DAEMON_DIRS[@]}"; do
    if [[ -d "${SRC}/${d}" ]]; then
        if ! cp -a "${SRC}/${d}" "${DST}/${d}"; then
            log "ERROR: failed to copy directory ${d}"
            exit 1
        fi
        copied=$((copied + 1))
    fi
done

# Normalize SELinux contexts on the migrated tree so anything host-side
# touching /var/lib/lifeos before the Quadlet's first start sees the
# correct var_lib_t labels (instead of the user_home_t the cp -a may have
# inherited).
if command -v restorecon >/dev/null 2>&1; then
    restorecon -R "$DST" 2>/dev/null || true
fi

log "migrated ${copied} item(s), ${skipped} optional file(s) absent — sibling trees (n/, models/, simplex/, ...) preserved"

if [[ -f "${DST}/memory.db" ]]; then
    log "memory.db ready at ${DST} ($(du -sh "${DST}/memory.db" | cut -f1))"
    log "first start of lifeos-lifeosd will read it with the same /etc/machine-id-derived key."
    exit 0
else
    log "ERROR: post-migration ${DST}/memory.db missing"
    exit 1
fi
