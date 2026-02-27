#!/bin/bash
# Enforces the minimum security baseline for LifeOS Phase 0:
# - Root filesystem encrypted with LUKS2
# - UEFI Secure Boot enabled
# - TPM presence (recommended, warning-only)
set -euo pipefail

ENFORCE=false
QUIET=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --enforce) ENFORCE=true ;;
        --quiet) QUIET=true ;;
    esac
    shift
done

if [[ -f /etc/lifeos/allow-insecure-platform ]]; then
    ENFORCE=false
fi

log() {
    if [[ "${QUIET}" != true ]]; then
        echo "$1"
    fi
}

warn() {
    echo "WARNING: $1" >&2
}

failures=()

check_secure_boot() {
    local var
    var="$(ls /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | head -n1 || true)"
    if [[ -z "${var}" ]]; then
        failures+=("UEFI Secure Boot variable not found")
        return
    fi

    local value
    value="$(od -An -t u1 -N 1 -j 4 "${var}" 2>/dev/null | tr -d ' ')"
    if [[ "${value}" != "1" ]]; then
        failures+=("Secure Boot is disabled")
    fi
}

check_luks2_root() {
    local root_source
    root_source="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
    if [[ -z "${root_source}" ]]; then
        failures+=("Unable to determine root filesystem source")
        return
    fi

    if [[ "${root_source}" != /dev/mapper/* && "${root_source}" != /dev/dm-* ]]; then
        failures+=("Root filesystem is not mounted through dm-crypt (${root_source})")
        return
    fi

    if ! command -v cryptsetup >/dev/null 2>&1; then
        warn "cryptsetup not installed; cannot verify LUKS version explicitly"
        return
    fi

    local mapper_name
    mapper_name="$(basename "${root_source}")"
    local status
    status="$(cryptsetup status "${mapper_name}" 2>/dev/null || true)"
    if [[ -z "${status}" ]]; then
        failures+=("Unable to inspect cryptsetup status for ${mapper_name}")
        return
    fi

    if ! grep -qi "type:[[:space:]]*LUKS2" <<< "${status}"; then
        failures+=("Root device ${mapper_name} is not LUKS2")
    fi
}

check_tpm_presence() {
    if [[ -c /dev/tpmrm0 || -c /dev/tpm0 ]]; then
        log "TPM device detected"
    else
        warn "TPM 2.0 device not detected (TPM unlock will be unavailable)"
    fi
}

check_secure_boot
check_luks2_root
check_tpm_presence

if [[ ${#failures[@]} -eq 0 ]]; then
    log "Security baseline passed (Secure Boot + LUKS2)"
    exit 0
fi

for failure in "${failures[@]}"; do
    echo "FAILED: ${failure}" >&2
done

if [[ "${ENFORCE}" == true ]]; then
    exit 1
fi

warn "Security baseline not enforced (non-enforcing mode)"
exit 0
