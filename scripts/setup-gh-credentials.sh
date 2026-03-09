#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Configure persistent GitHub/GHCR credentials for local development + Codex.
#------------------------------------------------------------------------------

set -euo pipefail

DEFAULT_ENV_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/lifeos/gh.env"
ENV_FILE="${DEFAULT_ENV_FILE}"
GH_USER="${GH_USER:-${LIFEOS_GHCR_USER:-}}"
GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-${LIFEOS_GHCR_TOKEN:-${CR_PAT:-}}}}"
TOKEN_FILE=""
ENABLE_SHELL_AUTOLOAD=true
LOGIN_GH=false
LOGIN_PODMAN=false
CHECK_GHCR=true

usage() {
    cat <<'EOF'
Usage:
  ./scripts/setup-gh-credentials.sh [options]

Options:
  --user USER            GitHub username (e.g. hectormr206)
  --token TOKEN          GitHub token (PAT). Avoid this in shared terminals/history.
  --token-file PATH      Read token from file PATH
  --env-file PATH        Output env file (default: ~/.config/lifeos/gh.env)
  --no-shell-autoload    Do not edit ~/.bashrc and ~/.zshrc
  --gh-login             Run non-interactive 'gh auth login' with token
  --podman-login         Run non-interactive 'podman login ghcr.io'
  --skip-ghcr-check      Skip GHCR manifest access check
  -h, --help             Show help
EOF
}

append_line_if_missing() {
    local file="$1"
    local line="$2"
    mkdir -p "$(dirname "$file")"
    touch "$file"
    if ! grep -Fq "$line" "$file"; then
        printf '\n%s\n' "$line" >> "$file"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)
            GH_USER="$2"
            shift 2
            ;;
        --token)
            GH_TOKEN="$2"
            shift 2
            ;;
        --token-file)
            TOKEN_FILE="$2"
            shift 2
            ;;
        --env-file)
            ENV_FILE="$2"
            shift 2
            ;;
        --no-shell-autoload)
            ENABLE_SHELL_AUTOLOAD=false
            shift
            ;;
        --gh-login)
            LOGIN_GH=true
            shift
            ;;
        --podman-login)
            LOGIN_PODMAN=true
            shift
            ;;
        --skip-ghcr-check)
            CHECK_GHCR=false
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

if [[ -n "$TOKEN_FILE" ]]; then
    [[ -r "$TOKEN_FILE" ]] || { echo "Cannot read token file: $TOKEN_FILE" >&2; exit 1; }
    GH_TOKEN="$(tr -d '\r\n' < "$TOKEN_FILE")"
fi

if [[ -z "$GH_USER" ]]; then
    read -r -p "GitHub username: " GH_USER
fi

if [[ -z "$GH_TOKEN" ]]; then
    read -r -s -p "GitHub token (PAT): " GH_TOKEN
    echo
fi

if [[ -z "$GH_USER" || -z "$GH_TOKEN" ]]; then
    echo "Both username and token are required." >&2
    exit 1
fi

mkdir -p "$(dirname "$ENV_FILE")"
umask 077
cat > "$ENV_FILE" <<EOF
export GH_HOST="github.com"
export GH_USER="${GH_USER}"
export GH_TOKEN="${GH_TOKEN}"
export GITHUB_TOKEN="${GH_TOKEN}"
export CR_PAT="${GH_TOKEN}"
export LIFEOS_GHCR_USER="${GH_USER}"
export LIFEOS_GHCR_TOKEN="${GH_TOKEN}"
EOF
chmod 600 "$ENV_FILE"

ln -sfn "$ENV_FILE" /tmp/lifeos-gh.env

if [[ "$ENABLE_SHELL_AUTOLOAD" == true ]]; then
    SHELL_LINE="[ -f \"$ENV_FILE\" ] && set -a && . \"$ENV_FILE\" && set +a"
    append_line_if_missing "$HOME/.bashrc" "$SHELL_LINE"
    append_line_if_missing "$HOME/.zshrc" "$SHELL_LINE"
fi

if [[ "$LOGIN_GH" == true ]]; then
    if command -v gh >/dev/null 2>&1; then
        # gh auth login refuses to store credentials when GH_TOKEN/GITHUB_TOKEN are set.
        # Use env -u for the gh process only; keep shell variables intact under set -u.
        printf "%s\n" "$GH_TOKEN" | env -u GH_TOKEN -u GITHUB_TOKEN -u CR_PAT \
            gh auth login --hostname github.com --with-token >/dev/null
    else
        echo "Skipping gh login: 'gh' command not found"
    fi
fi

if [[ "$LOGIN_PODMAN" == true ]]; then
    if command -v podman >/dev/null 2>&1; then
        printf "%s\n" "$GH_TOKEN" | podman login ghcr.io -u "$GH_USER" --password-stdin >/dev/null
    else
        echo "Skipping podman login: 'podman' command not found"
    fi
fi

if [[ "$CHECK_GHCR" == true ]] && (command -v podman >/dev/null 2>&1 || command -v skopeo >/dev/null 2>&1); then
    GHCR_IMAGE="ghcr.io/${GH_USER}/lifeos:edge"
    if command -v skopeo >/dev/null 2>&1; then
        if skopeo inspect --creds "${GH_USER}:${GH_TOKEN}" "docker://${GHCR_IMAGE}" >/dev/null 2>&1; then
            echo "GHCR check passed for ${GHCR_IMAGE} (skopeo inspect)"
        else
            echo "WARNING: GHCR manifest check failed for ${GHCR_IMAGE} (skopeo inspect)"
            echo "         Recreate PAT with Packages Read (and repo access if package is private)."
        fi
    elif command -v podman >/dev/null 2>&1; then
        if podman manifest inspect "docker://${GHCR_IMAGE}" >/dev/null 2>&1; then
            echo "GHCR check passed for ${GHCR_IMAGE} (podman manifest inspect)"
        else
            echo "WARNING: GHCR manifest check failed for ${GHCR_IMAGE} (podman manifest inspect)"
            echo "         Recreate PAT with Packages Read (and repo access if package is private)."
        fi
    fi
fi

echo "Saved credentials env: $ENV_FILE"
echo "Linked for Codex sessions: /tmp/lifeos-gh.env"
echo "To load now in current shell:"
echo "  set -a && . \"$ENV_FILE\" && set +a"
