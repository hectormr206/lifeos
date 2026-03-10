#!/usr/bin/env bash
# Build a daily-driver recovery kit:
# - Exports a Life Capsule backup
# - Captures system diagnostics
# - Writes a rollback/rescue runbook

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TIMESTAMP="$(date -u +%Y%m%d-%H%M%S)"

OUTPUT_DIR="${PROJECT_ROOT}/output/recovery-kit-${TIMESTAMP}"
IDENTITY_PATH="${HOME}/.config/lifeos/capsule/life-capsule.agekey"
RECIPIENT="${LIFEOS_CAPSULE_RECIPIENT:-}"
ISO_PATH=""
SKIP_CAPSULE=false

usage() {
    cat <<'EOF'
Usage: scripts/create-recovery-kit.sh [options]

Options:
  --output-dir PATH   Recovery kit output directory
  --recipient AGE1    Age recipient public key for capsule encryption
  --identity PATH     Age identity file path (used to infer/generate recipient)
  --iso PATH          Include ISO file in the kit (optional)
  --skip-capsule      Build kit without capsule export
  -h, --help          Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --recipient)
            RECIPIENT="$2"
            shift 2
            ;;
        --identity)
            IDENTITY_PATH="$2"
            shift 2
            ;;
        --iso)
            ISO_PATH="$2"
            shift 2
            ;;
        --skip-capsule)
            SKIP_CAPSULE=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1"
        exit 1
    fi
}

run_capture() {
    local title="$1"
    shift
    {
        echo "## ${title}"
        echo "\$ $*"
        "$@" 2>&1 || true
        echo
    } >> "${OUTPUT_DIR}/system-diagnostics.txt"
}

mkdir -p "${OUTPUT_DIR}"
require_cmd life
require_cmd sha256sum

if [[ -z "${ISO_PATH}" && -f "${PROJECT_ROOT}/output/lifeos-latest.iso" ]]; then
    ISO_PATH="${PROJECT_ROOT}/output/lifeos-latest.iso"
fi

CAPSULE_FILE=""
if [[ "${SKIP_CAPSULE}" = false ]]; then
    if [[ -z "${RECIPIENT}" && -f "${IDENTITY_PATH}.pub" ]]; then
        RECIPIENT="$(head -n1 "${IDENTITY_PATH}.pub" | tr -d '\r\n')"
    fi

    if [[ -z "${RECIPIENT}" ]]; then
        require_cmd age-keygen
        mkdir -p "$(dirname "${IDENTITY_PATH}")"
        if [[ ! -f "${IDENTITY_PATH}" ]]; then
            age-keygen -o "${IDENTITY_PATH}" >/dev/null
            chmod 600 "${IDENTITY_PATH}"
        fi
        age-keygen -y "${IDENTITY_PATH}" > "${IDENTITY_PATH}.pub"
        RECIPIENT="$(head -n1 "${IDENTITY_PATH}.pub" | tr -d '\r\n')"
    fi

    CAPSULE_FILE="${OUTPUT_DIR}/life-capsule-${TIMESTAMP}.capsule"
    life capsule export --recipient "${RECIPIENT}" --output "${CAPSULE_FILE}"
fi

if [[ -n "${ISO_PATH}" ]]; then
    if [[ ! -f "${ISO_PATH}" ]]; then
        echo "ISO file not found: ${ISO_PATH}"
        exit 1
    fi
    cp -f "${ISO_PATH}" "${OUTPUT_DIR}/$(basename "${ISO_PATH}")"
fi

{
    echo "LifeOS Recovery Kit - ${TIMESTAMP}"
    echo
    echo "Generated at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Host: $(hostname)"
} > "${OUTPUT_DIR}/system-diagnostics.txt"

run_capture "life version" life --version
run_capture "life status (json)" life status --json
run_capture "life update status" life update status
run_capture "kernel" uname -a
run_capture "os-release" cat /etc/os-release

if command -v bootc >/dev/null 2>&1; then
    if sudo -n true >/dev/null 2>&1; then
        run_capture "bootc status (sudo)" sudo bootc status
    else
        run_capture "bootc status" bootc status
    fi
fi

cat > "${OUTPUT_DIR}/ROLLBACK_RUNBOOK.md" <<EOF
# LifeOS Rollback Runbook

Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)

## 1. Health Check Before Changes
\`\`\`bash
life status
life update --dry
life recover
\`\`\`

## 2. Rollback After a Bad Update
\`\`\`bash
life rollback
sudo reboot
\`\`\`

Fallback path:
\`\`\`bash
sudo bootc rollback
sudo reboot
\`\`\`

## 3. Restore from Life Capsule
\`\`\`bash
life capsule restore --identity ${IDENTITY_PATH} ${CAPSULE_FILE:-<path-to-capsule>}
\`\`\`

## 4. Build a Rescue ISO
\`\`\`bash
sudo bash scripts/build-iso-without-model.sh
\`\`\`

The resulting ISO is usually at:
\`\`\`
output/lifeos-latest.iso
\`\`\`

## 5. Create a Bootable USB
\`\`\`bash
sudo dd if=output/lifeos-latest.iso of=/dev/sdX bs=4M status=progress oflag=sync
\`\`\`

## 6. VM Validation Loop
Use \`virt-manager\` or \`GNOME Boxes\` in LifeOS:
1. Create VM (UEFI, 4 vCPU, 8 GB RAM, 40 GB disk).
2. Attach \`output/lifeos-latest.iso\`.
3. Install LifeOS and run:
\`\`\`bash
life check
life status
life update --dry
life recover
\`\`\`
EOF

{
    echo "# SHA256 checksums"
    find "${OUTPUT_DIR}" -maxdepth 1 -type f -print0 | sort -z | xargs -0 sha256sum
} > "${OUTPUT_DIR}/SHA256SUMS.txt"

find "${OUTPUT_DIR}" -maxdepth 1 -type f | sort > "${OUTPUT_DIR}/MANIFEST.txt"

echo "Recovery kit created at: ${OUTPUT_DIR}"
echo "Runbook: ${OUTPUT_DIR}/ROLLBACK_RUNBOOK.md"
