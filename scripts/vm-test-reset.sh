#!/usr/bin/env bash
# LifeOS VM test helper:
# - Uses ISO from output/ and maps it for libvirt session access
#   (hardlink/reflink preferred to avoid duplicate storage)
# - Recreates VM cleanly to avoid stale storage growth
# - Defaults to a small test disk (20G)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ACTION="run"
VM_NAME="${LIFEOS_VM_NAME:-lifeos-phase3}"
CONNECT_URI="${LIFEOS_VM_CONNECT:-qemu:///session}"
ISO_PATH="${LIFEOS_VM_ISO:-${PROJECT_ROOT}/output/lifeos-latest.iso}"
ISO_EFFECTIVE_PATH="${ISO_PATH}"
DISK_SIZE_GB="${LIFEOS_VM_DISK_GB:-20}"
MEMORY_MB="${LIFEOS_VM_MEMORY_MB:-8192}"
VCPUS="${LIFEOS_VM_VCPUS:-4}"
GRAPHICS="${LIFEOS_VM_GRAPHICS:-spice}"
OS_VARIANT="${LIFEOS_VM_OS_VARIANT:-fedora-unknown}"
DISK_PATH="${LIFEOS_VM_DISK_PATH:-}"
NO_CLEAN=0
HEADLESS=0
UEFI=1

log() { echo "[vm-test] $*"; }
die() { echo "[vm-test][error] $*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage:
  $0 [run|clean|status] [options]

Options:
  --name NAME            VM name (default: ${VM_NAME})
  --connect URI          Libvirt URI (default: ${CONNECT_URI})
  --iso PATH             ISO path (default: ${ISO_PATH})
  --os-variant NAME      OS variant (default: ${OS_VARIANT})
  --disk-size GB         Disk size in GB (default: ${DISK_SIZE_GB})
  --disk-path PATH       Explicit qcow2 path
  --memory MB            VM RAM in MB (default: ${MEMORY_MB})
  --vcpus N              vCPU count (default: ${VCPUS})
  --graphics TYPE        Graphics mode (default: ${GRAPHICS})
  --headless             No GUI console
  --bios                 Disable UEFI boot
  --no-clean             Do not destroy previous VM before run
  -h, --help             Show this help

Examples:
  $0 run
  $0 run --disk-size 18 --memory 6144
  $0 clean
  $0 status
EOF
}

parse_args() {
    if [[ $# -gt 0 ]]; then
        case "$1" in
            run|clean|status)
                ACTION="$1"
                shift
                ;;
        esac
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name) VM_NAME="$2"; shift 2 ;;
            --connect) CONNECT_URI="$2"; shift 2 ;;
            --iso) ISO_PATH="$2"; shift 2 ;;
            --os-variant) OS_VARIANT="$2"; shift 2 ;;
            --disk-size) DISK_SIZE_GB="$2"; shift 2 ;;
            --disk-path) DISK_PATH="$2"; shift 2 ;;
            --memory) MEMORY_MB="$2"; shift 2 ;;
            --vcpus) VCPUS="$2"; shift 2 ;;
            --graphics) GRAPHICS="$2"; shift 2 ;;
            --headless) HEADLESS=1; shift ;;
            --bios) UEFI=0; shift ;;
            --no-clean) NO_CLEAN=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

resolve_defaults() {
    if [[ -z "${DISK_PATH}" ]]; then
        if [[ "${CONNECT_URI}" == "qemu:///system" ]]; then
            DISK_PATH="/var/lib/libvirt/images/${VM_NAME}.qcow2"
        else
            DISK_PATH="${HOME}/.local/share/libvirt/images/${VM_NAME}.qcow2"
        fi
    fi

    if [[ "${CONNECT_URI}" == "qemu:///system" ]]; then
        NETWORK_ARG="network=default,model=virtio"
        if [[ "${ISO_PATH}" == "${HOME}/"* || "${ISO_PATH}" == "/var/home/"* ]]; then
            log "Tip: qemu:///system may not read ISO in home paths without ACLs."
            log "For zero-copy ISO access, prefer --connect qemu:///session (default)."
        fi
    else
        NETWORK_ARG="user,model=virtio"
    fi
}

prepare_iso_path() {
    [[ -f "${ISO_PATH}" ]] || die "ISO not found: ${ISO_PATH}"

    if [[ "${CONNECT_URI}" == "qemu:///session" ]]; then
        local boot_dir="${HOME}/.local/share/libvirt/boot"
        local iso_name
        iso_name="$(basename "${ISO_PATH}")"
        local safe_iso="${boot_dir}/${iso_name}"

        mkdir -p "${boot_dir}"
        rm -f "${safe_iso}"

        # Prefer hardlink to avoid duplicated storage.
        if ln "${ISO_PATH}" "${safe_iso}" 2>/dev/null; then
            log "ISO mapped via hardlink: ${safe_iso}"
        # Fallback: CoW reflink copy (no real duplication on btrfs/xfs reflink).
        elif cp --reflink=always "${ISO_PATH}" "${safe_iso}" 2>/dev/null; then
            log "ISO mapped via reflink copy: ${safe_iso}"
        # Last resort: regular copy (duplicates data, but guarantees readability).
        elif cp "${ISO_PATH}" "${safe_iso}" 2>/dev/null; then
            log "ISO mapped via regular copy: ${safe_iso}"
            log "Warning: regular copy used; this consumes additional disk space."
        else
            die "Could not map ISO into ${boot_dir}. Check filesystem permissions."
        fi

        # Keep SELinux context compatible with qemu session when possible.
        if command -v chcon >/dev/null 2>&1; then
            chcon -t svirt_home_t "${safe_iso}" >/dev/null 2>&1 || true
        fi
        if command -v restorecon >/dev/null 2>&1; then
            restorecon -F "${safe_iso}" >/dev/null 2>&1 || true
        fi

        ISO_EFFECTIVE_PATH="${safe_iso}"
    else
        ISO_EFFECTIVE_PATH="${ISO_PATH}"
    fi
}

cleanup_vm() {
    log "Cleaning VM state for '${VM_NAME}' on ${CONNECT_URI}..."
    virsh -c "${CONNECT_URI}" destroy "${VM_NAME}" >/dev/null 2>&1 || true
    virsh -c "${CONNECT_URI}" undefine "${VM_NAME}" --nvram --remove-all-storage >/dev/null 2>&1 || true
    rm -f "${DISK_PATH}" || true
}

status_vm() {
    log "Connection: ${CONNECT_URI}"
    log "ISO (source): ${ISO_PATH}"
    log "ISO (effective): ${ISO_EFFECTIVE_PATH}"
    log "Disk: ${DISK_PATH}"
    log "Disk size: ${DISK_SIZE_GB}G"
    log "Memory: ${MEMORY_MB} MB, vCPUs: ${VCPUS}"
    log "VM list:"
    virsh -c "${CONNECT_URI}" list --all || true
}

run_vm() {
    prepare_iso_path
    mkdir -p "$(dirname "${DISK_PATH}")"

    if [[ "${NO_CLEAN}" -eq 0 ]]; then
        cleanup_vm
    fi

    log "Starting installer VM '${VM_NAME}'..."
    log "Using ISO: ${ISO_EFFECTIVE_PATH}"
    log "Disk: ${DISK_PATH} (${DISK_SIZE_GB}G)"

    args=(
        --connect "${CONNECT_URI}"
        --name "${VM_NAME}"
        --memory "${MEMORY_MB}"
        --vcpus "${VCPUS}"
        --cpu host-passthrough
        --disk "path=${DISK_PATH},size=${DISK_SIZE_GB},format=qcow2,bus=virtio"
        --cdrom "${ISO_EFFECTIVE_PATH}"
        --os-variant "${OS_VARIANT}"
        --network "${NETWORK_ARG}"
    )

    if [[ "${HEADLESS}" -eq 1 ]]; then
        args+=(--graphics none --noautoconsole)
    else
        args+=(--graphics "${GRAPHICS}")
        if [[ "${GRAPHICS}" == "spice" ]]; then
            # Required for host<->guest clipboard integration with spice-vdagent.
            args+=(--channel spicevmc)
        fi
    fi

    if [[ "${UEFI}" -eq 1 ]]; then
        args+=(--boot uefi)
    fi

    virt-install "${args[@]}"
}

main() {
    parse_args "$@"
    require_cmd virt-install
    require_cmd virsh
    resolve_defaults

    case "${ACTION}" in
        run) run_vm ;;
        clean) cleanup_vm ;;
        status) status_vm ;;
        *) die "Unsupported action: ${ACTION}" ;;
    esac
}

main "$@"
