#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Configure GitHub repository secrets for NVIDIA Secure Boot module signing.
#------------------------------------------------------------------------------

set -euo pipefail

REPO=""
KEY_FILE=""
CERT_DER_FILE=""
OUT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/lifeos/nvidia-secureboot"
GENERATE=false
FORCE=false
APPLY=false

usage() {
    cat <<'EOF'
Usage:
  ./scripts/setup-nvidia-signing-secrets.sh [options]

Options:
  --repo OWNER/REPO      GitHub repository (default: auto-detect from git origin)
  --private-key PATH     PEM private key path
  --cert-der PATH        DER public cert path
  --out-dir PATH         Output dir when --generate is used
  --generate             Generate a new RSA keypair + DER cert
  --force                Overwrite generated key/cert files if they already exist
  --apply                Push secrets to GitHub using gh CLI
  -h, --help             Show this help

Examples:
  # Generate keypair + upload to current repo
  ./scripts/setup-nvidia-signing-secrets.sh --generate --apply

  # Upload existing keypair
  ./scripts/setup-nvidia-signing-secrets.sh \
    --repo hectormr206/lifeos \
    --private-key ~/.config/lifeos/nvidia-secureboot/lifeos-nvidia-kmod-sign.key \
    --cert-der ~/.config/lifeos/nvidia-secureboot/lifeos-nvidia-kmod-sign.der \
    --apply
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

detect_repo_from_origin() {
    local origin
    origin="$(git config --get remote.origin.url 2>/dev/null || true)"
    [ -n "$origin" ] || return 1

    case "$origin" in
        git@github.com:*.git)
            echo "${origin#git@github.com:}" | sed 's/\.git$//'
            ;;
        https://github.com/*.git)
            echo "${origin#https://github.com/}" | sed 's/\.git$//'
            ;;
        https://github.com/*)
            echo "${origin#https://github.com/}"
            ;;
        *)
            return 1
            ;;
    esac
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)
            REPO="$2"
            shift 2
            ;;
        --private-key)
            KEY_FILE="$2"
            shift 2
            ;;
        --cert-der)
            CERT_DER_FILE="$2"
            shift 2
            ;;
        --out-dir)
            OUT_DIR="$2"
            shift 2
            ;;
        --generate)
            GENERATE=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --apply)
            APPLY=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
done

require_cmd base64
require_cmd openssl

if [[ "$GENERATE" == true ]]; then
    KEY_FILE="${KEY_FILE:-${OUT_DIR}/lifeos-nvidia-kmod-sign.key}"
    CERT_DER_FILE="${CERT_DER_FILE:-${OUT_DIR}/lifeos-nvidia-kmod-sign.der}"

    mkdir -p "${OUT_DIR}"
    chmod 700 "${OUT_DIR}"

    if [[ "$FORCE" != true ]] && { [[ -e "$KEY_FILE" ]] || [[ -e "$CERT_DER_FILE" ]]; }; then
        die "Key/cert already exist. Use --force to overwrite or provide explicit --private-key/--cert-der."
    fi

    openssl req -new -x509 -newkey rsa:4096 \
        -keyout "${KEY_FILE}" \
        -out "${CERT_DER_FILE}" \
        -outform DER \
        -nodes \
        -days 3650 \
        -subj "/CN=LifeOS NVIDIA Kmod Secure Boot/"

    chmod 600 "${KEY_FILE}"
    chmod 644 "${CERT_DER_FILE}"
    echo "Generated key:  ${KEY_FILE}"
    echo "Generated cert: ${CERT_DER_FILE}"
fi

[[ -n "${KEY_FILE}" ]] || die "Missing --private-key (or use --generate)."
[[ -n "${CERT_DER_FILE}" ]] || die "Missing --cert-der (or use --generate)."
[[ -r "${KEY_FILE}" ]] || die "Cannot read private key: ${KEY_FILE}"
[[ -r "${CERT_DER_FILE}" ]] || die "Cannot read DER cert: ${CERT_DER_FILE}"

KEY_B64="$(base64 < "${KEY_FILE}" | tr -d '\n')"
CERT_B64="$(base64 < "${CERT_DER_FILE}" | tr -d '\n')"

if [[ "$APPLY" == true ]]; then
    require_cmd gh
    gh auth status >/dev/null 2>&1 || die "gh is not authenticated. Run: gh auth login"

    if [[ -z "${REPO}" ]]; then
        REPO="$(detect_repo_from_origin || true)"
    fi
    [[ -n "${REPO}" ]] || die "Could not detect repository. Provide --repo OWNER/REPO."

    gh secret set LIFEOS_NVIDIA_KMOD_SIGN_KEY_B64 --repo "${REPO}" --body "${KEY_B64}"
    gh secret set LIFEOS_NVIDIA_KMOD_CERT_DER_B64 --repo "${REPO}" --body "${CERT_B64}"

    echo "Updated secrets in ${REPO}:"
    echo "  - LIFEOS_NVIDIA_KMOD_SIGN_KEY_B64"
    echo "  - LIFEOS_NVIDIA_KMOD_CERT_DER_B64"
    echo
    echo "Next step: rerun release workflow to publish signed image."
else
    echo "Secrets prepared but not uploaded."
    echo "Run with --apply to push to GitHub."
fi

