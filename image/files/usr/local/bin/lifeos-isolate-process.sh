#!/usr/bin/bash
# lifeos-isolate-process — controlled SIGSTOP wrapper used by security_ai.rs.
#
# Replaces the prior blanket `kill -STOP *` sudoers rule. Flow:
#   1. lifeosd writes the target PID to /run/lifeos/isolate-target (mode 0600).
#   2. lifeosd (wheel) invokes sudo /usr/local/bin/lifeos-isolate-process
#      — no args accepted.
#   3. This script reads the PID, walks /proc/<pid>/cgroup, and refuses to
#      STOP anything that isn't in a user-scope lifeos slice. It also refuses
#      PID 1 and any pid < 100 (reserved for systemd / kernel threads).
#   4. On success it sends SIGSTOP, logs the action, and wipes the target file.
set -eu

TARGET_FILE=/run/lifeos/isolate-target
LOG_TAG=lifeos-isolate-process

log() { logger -t "${LOG_TAG}" -- "$1"; }

[ -f "${TARGET_FILE}" ] || { log "refused: no target file"; exit 1; }

# Only allow root invocation — the sudoers rule enforces this, belt-and-suspenders.
if [ "$(id -u)" -ne 0 ]; then
    log "refused: must run as root"
    exit 1
fi

PID="$(head -n1 "${TARGET_FILE}" | tr -cd '0-9')"
rm -f "${TARGET_FILE}"

[ -n "${PID}" ] || { log "refused: empty pid"; exit 1; }
[ "${PID}" -ge 100 ] || { log "refused: pid ${PID} below safety floor"; exit 1; }
[ -r "/proc/${PID}/cgroup" ] || { log "refused: pid ${PID} vanished"; exit 1; }

CG="$(cat /proc/"${PID}"/cgroup 2>/dev/null || true)"
# Allow only pids inside a lifeos-managed slice or the interactive user session.
case "${CG}" in
    *lifeos*|*user-1000.slice*|*user@1000.service*) ;;
    *)
        log "refused: pid ${PID} not in a lifeos/user-1000 cgroup (got: ${CG})"
        exit 1
        ;;
esac

COMM="$(tr -d '\0' < /proc/"${PID}"/comm 2>/dev/null || echo unknown)"
kill -STOP "${PID}" && log "SIGSTOP sent to pid=${PID} comm=${COMM}"
