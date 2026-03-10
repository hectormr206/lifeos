#!/bin/bash
# LifeOS NVIDIA + Secure Boot helper
set -euo pipefail

CERT_PATH="/usr/share/lifeos/secureboot/lifeos-nvidia-kmod.der"
MODULE_PATH="/usr/lib/modules/$(uname -r)/extra/nvidia/nvidia.ko"

usage() {
    cat <<'EOF'
Usage:
  lifeos-nvidia-secureboot.sh status
  lifeos-nvidia-secureboot.sh enroll

Commands:
  status   Show NVIDIA/Secure Boot signing state
  enroll   Import LifeOS NVIDIA key into MOK (requires reboot confirmation in firmware UI)
EOF
}

secure_boot_enabled() {
    command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -qi "SecureBoot enabled"
}

nvidia_gpu_present() {
    command -v lspci >/dev/null 2>&1 && lspci 2>/dev/null | grep -Eqi 'vga|3d|display' && lspci 2>/dev/null | grep -Eqi 'nvidia'
}

key_enrolled() {
    if ! command -v mokutil >/dev/null 2>&1 || [ ! -f "${CERT_PATH}" ]; then
        return 1
    fi

    local test_out=""
    test_out="$(mokutil --test-key "${CERT_PATH}" 2>&1 || true)"
    if echo "${test_out}" | grep -Eqi 'already enrolled|is enrolled|enrolled'; then
        return 0
    fi

    if command -v openssl >/dev/null 2>&1; then
        local cert_fp=""
        cert_fp="$(openssl x509 -inform DER -in "${CERT_PATH}" -fingerprint -noout 2>/dev/null | sed 's/.*=//' | tr -d ':' | tr '[:upper:]' '[:lower:]')"
        if [ -n "${cert_fp}" ]; then
            if mokutil --list-enrolled 2>/dev/null | tr -d ':' | tr '[:upper:]' '[:lower:]' | grep -q "${cert_fp}"; then
                return 0
            fi
        fi
    fi

    return 1
}

cmd_status() {
    local signer=""
    local rc=0
    local cert_present=0
    local cert_enrolled=0

    echo "LifeOS NVIDIA Secure Boot status"
    echo "  Kernel: $(uname -r)"

    if secure_boot_enabled; then
        echo "  Secure Boot: enabled"
    else
        echo "  Secure Boot: disabled"
    fi

    if nvidia_gpu_present; then
        echo "  NVIDIA GPU: detected"
    else
        echo "  NVIDIA GPU: not detected"
    fi

    if [ -f "${MODULE_PATH}" ]; then
        signer="$(modinfo -F signer "${MODULE_PATH}" 2>/dev/null || true)"
        if [ -n "${signer}" ]; then
            echo "  nvidia.ko signer: ${signer}"
        else
            echo "  nvidia.ko signer: <unsigned>"
            rc=1
        fi
    else
        echo "  nvidia.ko path: missing (${MODULE_PATH})"
        rc=1
    fi

    if [ -f "${CERT_PATH}" ]; then
        cert_present=1
        echo "  LifeOS MOK cert: present (${CERT_PATH})"
        if key_enrolled; then
            cert_enrolled=1
            echo "  LifeOS MOK cert: enrolled"
        else
            echo "  LifeOS MOK cert: not enrolled"
            rc=1
        fi
    else
        echo "  LifeOS MOK cert: missing (${CERT_PATH})"
        rc=1
    fi

    if secure_boot_enabled && nvidia_gpu_present; then
        if [ "${rc}" -ne 0 ]; then
            echo
            echo "Action:"
            if [ "${cert_present}" -eq 0 ]; then
                echo "  This image is missing ${CERT_PATH}."
                echo "  Pull/update to a LifeOS image built with NVIDIA Secure Boot signing enabled"
                echo "  (LIFEOS_NVIDIA_KMOD_SIGN_KEY_B64 + LIFEOS_NVIDIA_KMOD_CERT_DER_B64)."
            elif [ -z "${signer}" ]; then
                echo "  NVIDIA module is unsigned; Secure Boot will reject modprobe."
                echo "  Update to a signed image build, then enroll the key:"
                echo "  sudo lifeos-nvidia-secureboot.sh enroll"
                echo "  sudo reboot"
            elif [ "${cert_enrolled}" -eq 0 ]; then
                echo "  sudo lifeos-nvidia-secureboot.sh enroll"
                echo "  sudo reboot"
            fi
        fi
    fi

    return "${rc}"
}

cmd_enroll() {
    if [ "$EUID" -ne 0 ]; then
        echo "Run as root (use sudo)."
        exit 1
    fi

    if ! command -v mokutil >/dev/null 2>&1; then
        echo "mokutil not found."
        exit 1
    fi

    if ! secure_boot_enabled; then
        echo "Secure Boot is disabled; no MOK enrollment needed."
        exit 0
    fi

    if [ ! -f "${CERT_PATH}" ]; then
        echo "Missing certificate: ${CERT_PATH}"
        echo "This deployment was likely built without NVIDIA Secure Boot signing args."
        echo "Update to a signed image build, then retry enrollment."
        exit 1
    fi

    if key_enrolled; then
        echo "LifeOS NVIDIA MOK key is already enrolled."
        exit 0
    fi

    echo "Importing ${CERT_PATH} into MOK..."
    echo "You will set a one-time password and confirm enrollment at next boot."
    local import_out=""
    import_out="$(mokutil --import "${CERT_PATH}" 2>&1 || true)"
    echo "${import_out}"

    if echo "${import_out}" | grep -Eqi 'already enrolled|skip'; then
        echo "LifeOS NVIDIA MOK key is already enrolled."
        exit 0
    fi

    echo
    echo "Pending enrollment created."
    echo "Next steps:"
    echo "  1) Reboot"
    echo "  2) In MOK Manager: Enroll MOK -> Continue -> Yes -> enter password"
    echo "  3) Boot back and verify with: nvidia-smi"
}

case "${1:-status}" in
    status)
        cmd_status
        ;;
    enroll)
        cmd_enroll
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage
        exit 1
        ;;
esac
