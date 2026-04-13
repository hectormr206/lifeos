#!/bin/bash
# Periodic cleanup for development-heavy LifeOS hosts.
# Keeps useful artifacts while deleting stale one-shot files.
set -euo pipefail

ENV_FILE="/etc/lifeos/maintenance-cleanup.env"
[ -f "${ENV_FILE}" ] && source "${ENV_FILE}"

SCREENSHOT_DIR="${SCREENSHOT_DIR:-/var/lib/lifeos/screenshots}"
SCREENSHOT_KEEP_COUNT="${SCREENSHOT_KEEP_COUNT:-120}"
SCREENSHOT_KEEP_DAYS="${SCREENSHOT_KEEP_DAYS:-2}"

AUDIO_DIR="${AUDIO_DIR:-/var/lib/lifeos/audio}"
AUDIO_KEEP_COUNT="${AUDIO_KEEP_COUNT:-120}"
AUDIO_KEEP_DAYS="${AUDIO_KEEP_DAYS:-2}"
TTS_DIR="${TTS_DIR:-/var/lib/lifeos/tts}"
TTS_KEEP_COUNT="${TTS_KEEP_COUNT:-120}"
TTS_KEEP_DAYS="${TTS_KEEP_DAYS:-2}"

RUNNER_DIR="${RUNNER_DIR:-/var/lib/lifeos/actions-runner}"
RUNNER_DIAG_KEEP_DAYS="${RUNNER_DIAG_KEEP_DAYS:-14}"
RUNNER_TEMP_KEEP_DAYS="${RUNNER_TEMP_KEEP_DAYS:-2}"
RUNNER_ACTIONS_KEEP_DAYS="${RUNNER_ACTIONS_KEEP_DAYS:-30}"
RUNNER_TARGET_KEEP_DAYS="${RUNNER_TARGET_KEEP_DAYS:-3}"

ISO_OUTPUT_DIRS="${ISO_OUTPUT_DIRS:-/var/home/lifeos/personalProjects/gama/lifeos/output}"
ISO_KEEP_LATEST="${ISO_KEEP_LATEST:-2}"
ISO_LOG_KEEP_DAYS="${ISO_LOG_KEEP_DAYS:-14}"
DEV_PROJECT_DIRS="${DEV_PROJECT_DIRS:-/var/home/lifeos/personalProjects/gama/lifeos}"
DEV_TARGET_PRUNE_ON_HIGH_DISK="${DEV_TARGET_PRUNE_ON_HIGH_DISK:-true}"
DEV_TARGET_PRUNE_THRESHOLD="${DEV_TARGET_PRUNE_THRESHOLD:-92}"

TMP_PURGE_DAYS="${TMP_PURGE_DAYS:-3}"
PODMAN_PRUNE_ENABLED="${PODMAN_PRUNE_ENABLED:-false}"
PODMAN_PRUNE_IMAGES="${PODMAN_PRUNE_IMAGES:-false}"
PODMAN_PRUNE_UNTIL="${PODMAN_PRUNE_UNTIL:-168h}"
BOOTC_CLEANUP_ENABLED="${BOOTC_CLEANUP_ENABLED:-true}"
FLATPAK_PRUNE_ENABLED="${FLATPAK_PRUNE_ENABLED:-true}"
JOURNAL_VACUUM_DAYS="${JOURNAL_VACUUM_DAYS:-14}"
BUILD_GUARD_ENABLED="${BUILD_GUARD_ENABLED:-true}"
BUILD_LOCK_FILES="${BUILD_LOCK_FILES:-/run/lifeos/build-iso.lock /run/lifeos/iso-build.lock /tmp/lifeos-build.lock}"
BUILD_PROCESS_PATTERN="${BUILD_PROCESS_PATTERN:-scripts/build-iso.sh|scripts/generate-iso-simple.sh|scripts/generate-iso.sh|bootc-image-builder|osbuild|xorriso|mkisofs|genisoimage|qemu-img}"

log() {
    printf '[lifeos-cleanup] %s\n' "$*"
}

run_cmd() {
    "$@" || true
}

is_build_guard_active() {
    [ "${BUILD_GUARD_ENABLED}" = "true" ] || return 1

    local lock_file
    for lock_file in ${BUILD_LOCK_FILES}; do
        if [ -f "${lock_file}" ]; then
            log "Build guard active: lock detected at ${lock_file}"
            return 0
        fi
    done

    if pgrep -f "${BUILD_PROCESS_PATTERN}" >/dev/null 2>&1; then
        log "Build guard active: matching build process is running"
        return 0
    fi

    return 1
}

prune_files_older_than() {
    local dir="$1"
    local days="$2"
    local pattern="$3"

    [ -d "${dir}" ] || return 0
    find "${dir}" -maxdepth 1 -type f -name "${pattern}" -mtime "+${days}" -delete 2>/dev/null || true
}

prune_keep_latest_files() {
    local dir="$1"
    local pattern="$2"
    local keep="$3"

    [ -d "${dir}" ] || return 0

    mapfile -t files < <(
        find "${dir}" -maxdepth 1 -type f -name "${pattern}" -printf '%T@ %p\n' 2>/dev/null \
            | sort -nr \
            | awk '{print $2}'
    )

    local total="${#files[@]}"
    [ "${total}" -gt "${keep}" ] || return 0

    local idx
    for ((idx = keep; idx < total; idx++)); do
        rm -f "${files[$idx]}" || true
    done
}

cleanup_screenshots() {
    [ -d "${SCREENSHOT_DIR}" ] || return 0
    log "Cleaning screenshots in ${SCREENSHOT_DIR}"
    prune_files_older_than "${SCREENSHOT_DIR}" "${SCREENSHOT_KEEP_DAYS}" "lifeos_screenshot_*.jpg"
    prune_keep_latest_files "${SCREENSHOT_DIR}" "lifeos_screenshot_*.jpg" "${SCREENSHOT_KEEP_COUNT}"
}

cleanup_voice_artifacts() {
    if [ -d "${AUDIO_DIR}" ]; then
        log "Cleaning always-on audio snippets in ${AUDIO_DIR}"
        prune_files_older_than "${AUDIO_DIR}" "${AUDIO_KEEP_DAYS}" "*.wav"
        prune_keep_latest_files "${AUDIO_DIR}" "*.wav" "${AUDIO_KEEP_COUNT}"
    fi

    if [ -d "${TTS_DIR}" ]; then
        log "Cleaning TTS outputs in ${TTS_DIR}"
        prune_files_older_than "${TTS_DIR}" "${TTS_KEEP_DAYS}" "*.wav"
        prune_keep_latest_files "${TTS_DIR}" "*.wav" "${TTS_KEEP_COUNT}"
    fi
}

runner_is_busy() {
    pgrep -f 'Runner.Worker' >/dev/null 2>&1
}

cleanup_runner() {
    [ -d "${RUNNER_DIR}" ] || return 0
    log "Cleaning GitHub runner artifacts in ${RUNNER_DIR}"

    prune_files_older_than "${RUNNER_DIR}/_diag" "${RUNNER_DIAG_KEEP_DAYS}" "*.log"
    prune_files_older_than "${RUNNER_DIR}" "7" "actions-runner-linux-*.tar.gz"

    if runner_is_busy; then
        log "Runner worker is active; skipping _work cleanup for safety"
        return 0
    fi

    find "${RUNNER_DIR}/_work/_temp" -mindepth 1 -maxdepth 1 -mtime "+${RUNNER_TEMP_KEEP_DAYS}" -exec rm -rf {} + 2>/dev/null || true
    find "${RUNNER_DIR}/_work/_actions" -mindepth 2 -maxdepth 2 -type d -mtime "+${RUNNER_ACTIONS_KEEP_DAYS}" -exec rm -rf {} + 2>/dev/null || true
    find "${RUNNER_DIR}/_work" -type d -name target -mtime "+${RUNNER_TARGET_KEEP_DAYS}" -prune -exec rm -rf {} + 2>/dev/null || true
}

cleanup_iso_outputs() {
    local dir
    for dir in ${ISO_OUTPUT_DIRS}; do
        [ -d "${dir}" ] || continue
        log "Cleaning ISO/build outputs in ${dir}"

        prune_keep_latest_files "${dir}" "*.iso" "${ISO_KEEP_LATEST}"
        prune_keep_latest_files "${dir}" "*.raw" "${ISO_KEEP_LATEST}"
        prune_keep_latest_files "${dir}" "*.qcow2" "${ISO_KEEP_LATEST}"
        prune_keep_latest_files "${dir}" "*.vmdk" "${ISO_KEEP_LATEST}"
        prune_keep_latest_files "${dir}" "*.img" "${ISO_KEEP_LATEST}"
        prune_files_older_than "${dir}" "${ISO_LOG_KEEP_DAYS}" "*.log"

        find "${dir}" -mindepth 1 -maxdepth 1 -type d \( -name bootiso -o -name image \) -mtime "+1" -exec rm -rf {} + 2>/dev/null || true
    done
}

is_build_busy() {
    pgrep -f 'cargo|rustc|bootc-image-builder|osbuild' >/dev/null 2>&1
}

cleanup_dev_targets_on_high_disk() {
    [ "${DEV_TARGET_PRUNE_ON_HIGH_DISK}" = "true" ] || return 0
    local usage
    usage="$(df --output=pcent /var 2>/dev/null | tail -1 | tr -dc '0-9' || echo 0)"

    if [ "${usage}" -lt "${DEV_TARGET_PRUNE_THRESHOLD}" ]; then
        return 0
    fi

    if is_build_busy; then
        log "High disk (${usage}%) but build tools are active; skipping dev target prune"
        return 0
    fi

    log "High disk (${usage}%), pruning dev target directories"
    local dir
    for dir in ${DEV_PROJECT_DIRS}; do
        [ -d "${dir}/target" ] || continue
        rm -rf "${dir}/target" || true
    done
}

cleanup_tmp() {
    log "Cleaning stale temporary build directories in /var/tmp"
    find /var/tmp -mindepth 1 -maxdepth 1 -type d \
        \( -name 'lifeos-*' -o -name 'bootc-image-builder-*' -o -name 'osbuild-*' \) \
        -mtime "+${TMP_PURGE_DAYS}" -exec rm -rf {} + 2>/dev/null || true
}

cleanup_podman() {
    [ "${PODMAN_PRUNE_ENABLED}" = "true" ] || return 0
    command -v podman >/dev/null 2>&1 || return 0
    log "Pruning podman stale build/runtime data"
    if [ "${PODMAN_PRUNE_IMAGES}" = "true" ]; then
        run_cmd podman image prune -f
    fi
    run_cmd podman container prune -f --filter "until=${PODMAN_PRUNE_UNTIL}"
    run_cmd podman builder prune -f --filter "until=${PODMAN_PRUNE_UNTIL}"
}

cleanup_bootc() {
    [ "${BOOTC_CLEANUP_ENABLED}" = "true" ] || return 0
    command -v bootc >/dev/null 2>&1 || return 0
    log "Running bootc cleanup"
    run_cmd bootc cleanup
}

cleanup_flatpak() {
    [ "${FLATPAK_PRUNE_ENABLED}" = "true" ] || return 0
    command -v flatpak >/dev/null 2>&1 || return 0
    log "Pruning unused flatpak runtimes"
    run_cmd flatpak uninstall --unused -y --system
    if id -u lifeos >/dev/null 2>&1; then
        run_cmd runuser -u lifeos -- flatpak uninstall --unused -y --user
    fi
}

cleanup_journal() {
    command -v journalctl >/dev/null 2>&1 || return 0
    log "Vacuuming journal to ${JOURNAL_VACUUM_DAYS}d"
    run_cmd journalctl --vacuum-time="${JOURNAL_VACUUM_DAYS}d"
}

main() {
    log "Starting maintenance cleanup"
    if is_build_guard_active; then
        log "Skipping cleanup because ISO/image build is in progress"
        exit 0
    fi
    cleanup_screenshots
    cleanup_voice_artifacts
    cleanup_runner
    cleanup_iso_outputs
    cleanup_dev_targets_on_high_disk
    cleanup_tmp
    cleanup_podman
    cleanup_bootc
    cleanup_flatpak
    cleanup_journal
    log "Maintenance cleanup finished"
}

main "$@"
