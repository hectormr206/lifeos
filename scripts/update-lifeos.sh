#!/usr/bin/env bash
#===============================================================================
# LifeOS Robust Update Helper
#===============================================================================
# Provides a resilient update flow for bootc-based LifeOS hosts:
#   1) Pull image with podman (timeout protected)
#   2) Fallback to skopeo docker-archive + podman load if pull stalls/fails
#   3) Optional bootc switch/apply/reboot flow
#
# Examples:
#   sudo ./scripts/update-lifeos.sh --channel stable --switch --apply
#   sudo ./scripts/update-lifeos.sh --image ghcr.io/hectormr206/lifeos:stable --apply --reboot
#===============================================================================

set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()     { echo -e "${BLUE}[LifeOS]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
fatal()   {
    echo -e "${RED}[ERROR]${NC} $1"
    if [[ -n "${LOG_FILE:-}" ]]; then
        echo "Log file: ${LOG_FILE}"
    fi
    exit 1
}

DEFAULT_IMAGE="ghcr.io/hectormr206/lifeos:stable"
IMAGE="${LIFEOS_IMAGE:-$DEFAULT_IMAGE}"
IMAGE_EXPLICIT=false
CHANNEL=""
SWITCH_STREAM=false
APPLY_UPDATE=false
REBOOT_AFTER_APPLY=false
RESET_STORAGE=false
KEEP_ARCHIVE=false
ASSUME_YES=false
SKIP_PULL=false
ARCHIVE_PATH=""
ARCHIVE_DIR="${LIFEOS_ARCHIVE_DIR:-/var/tmp}"
PULL_TIMEOUT="${PODMAN_PULL_TIMEOUT:-1800}"
LOGIN_USER=""
LOGIN_TOKEN_ENV=""
LOGIN_TOKEN_FILE=""
LOCAL_SWITCH_REF=""
LOG_FILE="${LIFEOS_UPDATE_LOG_FILE:-}"
LOG_DIR="${LIFEOS_UPDATE_LOG_DIR:-/var/log/lifeos}"
LOG_INITIALIZED=false
ERROR_HANDLED=false
PULL_LAST_OUTPUT=""
PULL_LAST_RC=0

show_help() {
    cat << EOF
LifeOS Robust Update Helper

USAGE:
  sudo ./scripts/update-lifeos.sh [OPTIONS]

OPTIONS:
  -c, --channel CH       Update channel image: stable|candidate|edge
  -i, --image IMAGE      Full image reference (default: ${DEFAULT_IMAGE})
      --login-user USER  Run 'podman login ghcr.io -u USER' before pull
      --login-token-env V Read login token from env var name V (non-interactive login)
      --login-token-file P Read login token from file path P (non-interactive login)
      --skip-pull        Skip image pull/import phase (only bootc operations)
      --switch           Run bootc switch before upgrade checks (prefers local containers-storage)
      --apply            Run 'bootc upgrade --apply'
      --reboot           Reboot after a successful --apply
      --reset-storage    Run 'podman system reset -f' before pull (DESTRUCTIVE)
      --archive PATH     Custom docker-archive path for skopeo fallback
      --keep-archive     Keep fallback archive tar after podman load
      --pull-timeout SEC Pull timeout in seconds (default: ${PULL_TIMEOUT})
      --log-file PATH    Write logs to a custom file path
  -y, --yes              Non-interactive mode (auto-confirm risky steps)
  -h, --help             Show this help

ENV:
  LIFEOS_IMAGE           Override default image reference
  LIFEOS_ARCHIVE_DIR     Directory for fallback archive (default: /var/tmp)
  PODMAN_PULL_TIMEOUT    Pull timeout in seconds (default: 1800)
  LIFEOS_UPDATE_LOG_FILE Custom log file path
  LIFEOS_UPDATE_LOG_DIR  Default log directory (default: /var/log/lifeos)
  LIFEOS_GHCR_USER       Default GHCR user for --login-user
  LIFEOS_GHCR_TOKEN      Default GHCR token for non-interactive login
EOF
}

confirm() {
    local prompt="$1"
    if [[ "${ASSUME_YES}" == true ]]; then
        return 0
    fi
    read -r -p "${prompt} [y/N]: " answer
    case "${answer}" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

require_command() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || fatal "Missing required command: $cmd"
}

init_logging() {
    local ts

    if [[ -z "${LOG_FILE}" ]]; then
        ts="$(date +%Y%m%d-%H%M%S)"
        if mkdir -p "${LOG_DIR}" 2>/dev/null; then
            LOG_FILE="${LOG_DIR}/update-lifeos-${ts}.log"
        else
            LOG_FILE="/var/tmp/update-lifeos-${ts}.log"
            mkdir -p /var/tmp
        fi
    else
        mkdir -p "$(dirname "${LOG_FILE}")"
    fi

    touch "${LOG_FILE}" || fatal "Cannot write log file: ${LOG_FILE}"

    # Mirror all stdout/stderr to terminal + file.
    exec > >(tee -a "${LOG_FILE}") 2>&1
    LOG_INITIALIZED=true
    log "Logging to ${LOG_FILE}"
}

on_error() {
    local exit_code="$1"
    local line="$2"
    local cmd="$3"

    trap - ERR

    if [[ "${ERROR_HANDLED}" == true ]]; then
        exit "${exit_code}"
    fi
    ERROR_HANDLED=true

    set +e
    echo
    echo -e "${RED}[ERROR]${NC} Failure detected (exit=${exit_code}) at line ${line}"
    echo "Command: ${cmd}"
    echo "Collecting diagnostics..."
    echo
    echo "----- ERROR SNAPSHOT BEGIN -----"
    echo "Timestamp: $(date -Iseconds)"
    echo "Exit code: ${exit_code}"
    echo "Line: ${line}"
    echo "Command: ${cmd}"
    echo "Kernel: $(uname -a 2>/dev/null || true)"
    echo
    echo "[Disk usage]"
    df -h || true
    echo
    echo "[Inode usage]"
    df -i || true
    echo
    if command -v bootc >/dev/null 2>&1; then
        echo "[bootc status]"
        bootc status || true
        echo
    fi
    if command -v podman >/dev/null 2>&1; then
        echo "[podman info --debug]"
        podman info --debug || podman info || true
        echo
    fi
    if command -v journalctl >/dev/null 2>&1; then
        echo "[journalctl: bootc/podman (last 120 lines each)]"
        journalctl -b -u bootc --no-pager -n 120 || true
        journalctl -b -u podman --no-pager -n 120 || true
        echo
    fi
    echo "----- ERROR SNAPSHOT END -----"
    echo
    echo "Detailed log saved at: ${LOG_FILE}"
    exit "${exit_code}"
}

on_exit() {
    local exit_code="$1"
    if [[ "${LOG_INITIALIZED}" == true ]]; then
        if [[ "${exit_code}" -eq 0 ]]; then
            success "Log saved at ${LOG_FILE}"
        else
            warn "Log saved at ${LOG_FILE}"
        fi
    fi
}

check_free_space_gb() {
    local path="$1"
    local min_gb="$2"
    local df_out
    local available_gb

    if ! df_out="$(df -BG "$path" 2>/dev/null)"; then
        warn "Could not check free space for $path"
        return
    fi

    available_gb="$(echo "$df_out" | awk 'NR==2 {gsub(/G/, "", $4); print $4}')"
    if [[ -z "${available_gb}" ]]; then
        warn "Could not determine free space for $path"
        return
    fi
    if (( available_gb < min_gb )); then
        warn "Low free space at $path: ${available_gb}GB available, ${min_gb}GB recommended"
    else
        success "Free space at $path: ${available_gb}GB"
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--channel)
                CHANNEL="$2"
                shift 2
                ;;
            -i|--image)
                IMAGE="$2"
                IMAGE_EXPLICIT=true
                shift 2
                ;;
            --login-user)
                LOGIN_USER="$2"
                shift 2
                ;;
            --login-token-env)
                LOGIN_TOKEN_ENV="$2"
                shift 2
                ;;
            --login-token-file)
                LOGIN_TOKEN_FILE="$2"
                shift 2
                ;;
            --skip-pull)
                SKIP_PULL=true
                shift
                ;;
            --switch)
                SWITCH_STREAM=true
                shift
                ;;
            --apply)
                APPLY_UPDATE=true
                shift
                ;;
            --reboot)
                REBOOT_AFTER_APPLY=true
                shift
                ;;
            --reset-storage)
                RESET_STORAGE=true
                shift
                ;;
            --archive)
                ARCHIVE_PATH="$2"
                shift 2
                ;;
            --keep-archive)
                KEEP_ARCHIVE=true
                shift
                ;;
            --pull-timeout)
                PULL_TIMEOUT="$2"
                shift 2
                ;;
            --log-file)
                LOG_FILE="$2"
                shift 2
                ;;
            -y|--yes)
                ASSUME_YES=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                fatal "Unknown option: $1"
                ;;
        esac
    done
}

resolve_image() {
    if [[ -n "${CHANNEL}" ]]; then
        case "${CHANNEL}" in
            stable|candidate|edge) ;;
            *) fatal "Invalid --channel '${CHANNEL}'. Use stable|candidate|edge." ;;
        esac
        if [[ "${IMAGE_EXPLICIT}" == true ]]; then
            fatal "Use either --channel or --image, not both."
        fi
        IMAGE="ghcr.io/hectormr206/lifeos:${CHANNEL}"
    fi
}

resolve_login_credentials() {
    local token_from_env=""
    local login_token=""

    if [[ -z "${LOGIN_USER}" ]]; then
        LOGIN_USER="${LIFEOS_GHCR_USER:-${GH_USER:-${GITHUB_USER:-}}}"
    fi

    if [[ -n "${LOGIN_TOKEN_FILE}" ]]; then
        [[ -r "${LOGIN_TOKEN_FILE}" ]] || fatal "Cannot read --login-token-file: ${LOGIN_TOKEN_FILE}"
        login_token="$(tr -d '\r\n' < "${LOGIN_TOKEN_FILE}")"
    elif [[ -n "${LOGIN_TOKEN_ENV}" ]]; then
        token_from_env="${!LOGIN_TOKEN_ENV-}"
        login_token="$(printf "%s" "${token_from_env}" | tr -d '\r\n')"
    else
        for token_var in LIFEOS_GHCR_TOKEN GH_TOKEN GITHUB_TOKEN CR_PAT; do
            token_from_env="${!token_var-}"
            if [[ -n "${token_from_env}" ]]; then
                login_token="$(printf "%s" "${token_from_env}" | tr -d '\r\n')"
                break
            fi
        done
    fi

    if [[ -n "${LOGIN_USER}" && -n "${login_token}" ]]; then
        log "Running non-interactive podman login for ghcr.io as ${LOGIN_USER}"
        printf "%s\n" "${login_token}" | podman login ghcr.io -u "${LOGIN_USER}" --password-stdin
    elif [[ -n "${LOGIN_USER}" ]]; then
        log "Running podman login for ghcr.io as ${LOGIN_USER}"
        podman login ghcr.io -u "${LOGIN_USER}"
    elif [[ -n "${LOGIN_TOKEN_ENV}" || -n "${LOGIN_TOKEN_FILE}" ]]; then
        fatal "Token source provided but --login-user (or LIFEOS_GHCR_USER/GH_USER env) is missing."
    fi
}

is_auth_failure_output() {
    local msg="$1"
    echo "${msg}" | grep -Eqi \
        'invalid token|unauthorized|invalid username|auth token|requested access .* denied|reading manifest .* denied|denied'
}

print_ghcr_auth_guidance() {
    if [[ "${IMAGE}" != ghcr.io/* ]]; then
        warn "Registry authorization failed for ${IMAGE}."
        return
    fi

    warn "GHCR denied manifest access for ${IMAGE}."
    echo "This usually means:"
    echo "  1) Token is valid enough for 'login' but lacks Packages read access, or"
    echo "  2) Token is tied to an account without access to this private package."
    echo
    echo "Use a PAT with at least:"
    echo "  - Classic token: read:packages (and repo if package is private/repo-scoped)"
    echo "  - Fine-grained token: Packages=Read on the owner/repository"
    echo
    echo "Quick checks:"
    echo "  sudo podman manifest inspect \"docker://${IMAGE}\""
    if [[ -n "${LOGIN_USER}" ]]; then
        echo "  sudo skopeo inspect --creds \"${LOGIN_USER}:<TOKEN>\" \"docker://${IMAGE}\""
    fi
}

derive_local_switch_ref() {
    local image_no_digest
    local image_tail
    local image_name
    local image_tag

    image_no_digest="${IMAGE%@*}"
    image_tail="${image_no_digest##*/}"
    image_name="${image_tail%%:*}"
    image_tag="latest"

    if [[ "${image_tail}" == *:* ]]; then
        image_tag="${image_tail##*:}"
    fi

    LOCAL_SWITCH_REF="localhost/${image_name}:${image_tag}"
}

ghcr_connectivity_check() {
    local status

    if ! command -v curl >/dev/null 2>&1; then
        return 0
    fi

    status="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 https://ghcr.io/v2/ || echo "000")"
    case "${status}" in
        200|401)
            success "GHCR connectivity check passed (HTTP ${status})"
            ;;
        *)
            warn "GHCR connectivity check failed (HTTP ${status}, continuing anyway)"
            ;;
    esac
}

prepare_local_switch_ref() {
    if [[ -z "${LOCAL_SWITCH_REF}" ]]; then
        return 0
    fi

    if podman image exists "${IMAGE}"; then
        podman tag "${IMAGE}" "${LOCAL_SWITCH_REF}"
        success "Prepared local switch reference: ${LOCAL_SWITCH_REF}"
        return 0
    fi

    if podman image exists "${LOCAL_SWITCH_REF}"; then
        success "Local switch reference already available: ${LOCAL_SWITCH_REF}"
        return 0
    fi

    warn "Could not prepare local switch reference from ${IMAGE}"
}

bootc_switch_with_fallback() {
    local out
    local rc=0

    if [[ -n "${LOCAL_SWITCH_REF}" ]] && podman image exists "${LOCAL_SWITCH_REF}"; then
        log "Switching via local containers-storage reference: ${LOCAL_SWITCH_REF}"
        bootc switch --transport containers-storage "${LOCAL_SWITCH_REF}"
        return 0
    fi

    set +e
    out="$(bootc switch "${IMAGE}" 2>&1)"
    rc=$?
    set -e
    echo "${out}"

    if [[ ${rc} -eq 0 ]]; then
        return 0
    fi

    if [[ -n "${LOCAL_SWITCH_REF}" ]] && podman image exists "${LOCAL_SWITCH_REF}" && \
       echo "${out}" | grep -Eqi 'unauthorized|invalid username|auth token|denied'; then
        warn "Registry auth failed during bootc switch; retrying with local containers-storage"
        bootc switch --transport containers-storage "${LOCAL_SWITCH_REF}"
        return 0
    fi

    return "${rc}"
}

podman_pull_with_timeout() {
    local rc=0
    local out=""
    if command -v timeout >/dev/null 2>&1; then
        set +e
        out="$(timeout "${PULL_TIMEOUT}" podman pull "${IMAGE}" 2>&1)"
        rc=$?
        set -e
    else
        set +e
        out="$(podman pull "${IMAGE}" 2>&1)"
        rc=$?
        set -e
    fi

    PULL_LAST_OUTPUT="${out}"
    PULL_LAST_RC="${rc}"
    echo "${out}"

    return "$rc"
}

skopeo_fallback_pull() {
    require_command skopeo
    mkdir -p "${ARCHIVE_DIR}"

    local archive_file
    if [[ -n "${ARCHIVE_PATH}" ]]; then
        archive_file="${ARCHIVE_PATH}"
        mkdir -p "$(dirname "${archive_file}")"
    else
        local sanitized
        sanitized="$(echo "${IMAGE}" | tr '/:@' '___')"
        archive_file="${ARCHIVE_DIR}/lifeos-${sanitized}-$(date +%Y%m%d-%H%M%S).tar"
    fi

    check_free_space_gb "$(dirname "${archive_file}")" 30

    log "Fallback: skopeo copy docker://${IMAGE} -> docker-archive:${archive_file}"
    skopeo copy "docker://${IMAGE}" "docker-archive:${archive_file}:${IMAGE}"

    log "Loading archive into podman storage"
    podman load -i "${archive_file}"

    if [[ "${KEEP_ARCHIVE}" == true ]]; then
        success "Archive kept at ${archive_file}"
    else
        rm -f "${archive_file}"
        success "Archive removed: ${archive_file}"
    fi
}

main() {
    parse_args "$@"
    init_logging
    trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR
    trap 'on_exit $?' EXIT
    resolve_image
    derive_local_switch_ref

    [[ $EUID -eq 0 ]] || fatal "Run as root (use sudo)."
    require_command bootc
    require_command podman

    log "Target image: ${IMAGE}"
    log "Local switch ref: ${LOCAL_SWITCH_REF}"
    log "Pull timeout: ${PULL_TIMEOUT}s"
    log "Actions: switch=${SWITCH_STREAM}, apply=${APPLY_UPDATE}, reboot=${REBOOT_AFTER_APPLY}, skip_pull=${SKIP_PULL}"
    ghcr_connectivity_check

    resolve_login_credentials

    if [[ "${RESET_STORAGE}" == true ]]; then
        warn "This will remove all rootful podman images/containers on this host."
        if confirm "Proceed with 'podman system reset -f'?"; then
            podman system reset -f
            success "Podman storage reset completed"
        else
            fatal "Aborted by user."
        fi
    fi

    if [[ "${SKIP_PULL}" == false ]]; then
        check_free_space_gb "/var/lib/containers" 20
        check_free_space_gb "${ARCHIVE_DIR}" 30

        log "Attempting podman pull"
        if podman_pull_with_timeout; then
            success "podman pull completed"
        else
            if is_auth_failure_output "${PULL_LAST_OUTPUT}"; then
                print_ghcr_auth_guidance
                fatal "Cannot pull ${IMAGE}: registry authorization denied."
            fi
            warn "podman pull failed or timed out; using skopeo fallback"
            skopeo_fallback_pull
        fi

        if podman image exists "${IMAGE}"; then
            success "Image is available locally: ${IMAGE}"
        else
            warn "Image existence check by exact reference failed; listing recent images"
            podman images --format "table {{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedAt}}" | head -n 10
        fi

        if [[ "${SWITCH_STREAM}" == true ]]; then
            prepare_local_switch_ref
        fi
    elif [[ "${SWITCH_STREAM}" == true ]]; then
        prepare_local_switch_ref
    fi

    log "Current bootc status"
    bootc status || true

    if [[ "${SWITCH_STREAM}" == true ]]; then
        if [[ -n "${LOCAL_SWITCH_REF}" ]] && podman image exists "${LOCAL_SWITCH_REF}"; then
            if confirm "Run 'bootc switch --transport containers-storage ${LOCAL_SWITCH_REF}' now?"; then
                bootc_switch_with_fallback
                success "bootc switch completed"
            else
                fatal "Aborted by user."
            fi
        elif confirm "Run 'bootc switch ${IMAGE}' now?"; then
            bootc_switch_with_fallback
            success "bootc switch completed"
        else
            fatal "Aborted by user."
        fi
    fi

    log "Running bootc upgrade --check"
    bootc upgrade --check || warn "bootc upgrade --check reported issues"

    if [[ "${APPLY_UPDATE}" == true ]]; then
        if confirm "Run 'bootc upgrade --apply' now?"; then
            bootc upgrade --apply
            success "bootc upgrade --apply completed"
        else
            fatal "Aborted by user."
        fi
    fi

    log "Final bootc status"
    bootc status || true

    echo
    success "Update flow completed."
    echo "If anything fails after reboot, rollback with:"
    echo "  sudo bootc rollback && sudo reboot"

    if [[ "${APPLY_UPDATE}" == true && "${REBOOT_AFTER_APPLY}" == true ]]; then
        if confirm "Reboot now?"; then
            reboot
        else
            warn "Reboot skipped by user. Remember to reboot manually."
        fi
    elif [[ "${APPLY_UPDATE}" == true ]]; then
        warn "Update applied. Reboot is required to boot into the new deployment."
    fi
}

main "$@"
