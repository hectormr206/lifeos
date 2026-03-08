#!/usr/bin/env bash
# Configure a GitHub Actions self-hosted runner on LifeOS/bootc hosts.
# This script must run on the host (not inside toolbox/containers).
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  scripts/setup-self-hosted-runner.sh --url <repo-or-org-url> --token <registration-token> [options]

Required:
  --url URL                GitHub URL for runner registration.
                           Examples:
                             https://github.com/<owner>/<repo>
                             https://github.com/<org>
  --token TOKEN            GitHub runner registration token (short-lived).

Optional:
  --name NAME              Runner name (default: <hostname>-lifeos)
  --user USER              System user running the service (default: current user)
  --labels CSV             Extra labels comma-separated (default: lifeos,bootc)
  --dir PATH               Runner install dir (default: /var/lib/lifeos/actions-runner)
  --work-dir NAME          Runner work dir name (default: _work)
  --runner-group NAME      Runner group (default: Default)
  --version VERSION        Runner version (default: latest from GitHub API)
  --force-reconfigure      Reconfigure existing runner registration
  -h, --help               Show help

Notes:
  - Run on the LifeOS host shell ([user@fedora ...]), not in toolbox.
  - The script enables user linger and podman socket for Docker-compatible actions.
EOF
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "ERROR: missing required command: $1" >&2
        exit 1
    fi
}

RUNNER_URL=""
RUNNER_TOKEN=""
HOST_SHORT="$(hostname 2>/dev/null || true)"
HOST_SHORT="${HOST_SHORT%%.*}"
RUNNER_NAME="${HOST_SHORT:-lifeos}-lifeos"
RUNNER_USER="$(id -un)"
RUNNER_LABELS="lifeos,bootc"
RUNNER_DIR="/var/lib/lifeos/actions-runner"
RUNNER_WORK_DIR="_work"
RUNNER_GROUP="Default"
RUNNER_VERSION=""
FORCE_RECONFIGURE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --url)
            RUNNER_URL="${2:-}"
            shift 2
            ;;
        --token)
            RUNNER_TOKEN="${2:-}"
            shift 2
            ;;
        --name)
            RUNNER_NAME="${2:-}"
            shift 2
            ;;
        --user)
            RUNNER_USER="${2:-}"
            shift 2
            ;;
        --labels)
            RUNNER_LABELS="${2:-}"
            shift 2
            ;;
        --dir)
            RUNNER_DIR="${2:-}"
            shift 2
            ;;
        --work-dir)
            RUNNER_WORK_DIR="${2:-}"
            shift 2
            ;;
        --runner-group)
            RUNNER_GROUP="${2:-}"
            shift 2
            ;;
        --version)
            RUNNER_VERSION="${2:-}"
            shift 2
            ;;
        --force-reconfigure)
            FORCE_RECONFIGURE=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            usage
            exit 1
            ;;
    esac
done

if [[ -z "$RUNNER_URL" || -z "$RUNNER_TOKEN" ]]; then
    echo "ERROR: --url and --token are required" >&2
    usage
    exit 1
fi

require_cmd sudo
require_cmd curl
require_cmd tar
require_cmd jq
require_cmd systemctl
require_cmd loginctl
require_cmd uname

if ! getent passwd "$RUNNER_USER" >/dev/null 2>&1; then
    echo "ERROR: user '$RUNNER_USER' does not exist" >&2
    exit 1
fi

if ! command -v podman >/dev/null 2>&1; then
    echo "ERROR: podman is required for Docker-compatible GitHub Actions jobs" >&2
    exit 1
fi

if [[ "${RUNNER_DIR}" != /var/* ]]; then
    echo "WARNING: using non-/var runner dir on an image-mode host may not survive updates."
fi

arch="$(uname -m)"
case "$arch" in
    x86_64) runner_arch="x64" ;;
    aarch64|arm64) runner_arch="arm64" ;;
    *)
        echo "ERROR: unsupported architecture: $arch" >&2
        exit 1
        ;;
esac

if [[ -z "$RUNNER_VERSION" ]]; then
    RUNNER_VERSION="$(
        curl -fsSL "https://api.github.com/repos/actions/runner/releases/latest" \
        | jq -r '.tag_name' \
        | sed 's/^v//'
    )"
fi

if [[ -z "$RUNNER_VERSION" || "$RUNNER_VERSION" == "null" ]]; then
    echo "ERROR: could not resolve runner version" >&2
    exit 1
fi

runner_tgz="actions-runner-linux-${runner_arch}-${RUNNER_VERSION}.tar.gz"
runner_url="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${runner_tgz}"

runner_uid="$(id -u "$RUNNER_USER")"
docker_host="unix:///run/user/${runner_uid}/podman/podman.sock"

echo "==> Preparing directories"
sudo mkdir -p "$RUNNER_DIR"
sudo chown -R "$RUNNER_USER":"$RUNNER_USER" "$RUNNER_DIR"

echo "==> Downloading GitHub runner ${RUNNER_VERSION} (${runner_arch})"
if [[ ! -f "${RUNNER_DIR}/${runner_tgz}" ]]; then
    sudo -u "$RUNNER_USER" curl -fL "${runner_url}" -o "${RUNNER_DIR}/${runner_tgz}"
fi

echo "==> Extracting runner package"
sudo -u "$RUNNER_USER" tar xzf "${RUNNER_DIR}/${runner_tgz}" -C "$RUNNER_DIR"

if [[ ! -x "${RUNNER_DIR}/config.sh" ]]; then
    echo "ERROR: runner files were not extracted correctly to ${RUNNER_DIR}" >&2
    exit 1
fi

echo "==> Ensuring runner executables are executable"
sudo -u "$RUNNER_USER" bash -lc "cd '${RUNNER_DIR}' && chmod +x ./*.sh ./bin/* ./externals/*/bin/* 2>/dev/null || true"

if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled; then
    echo "==> SELinux detected; labeling runner executables for execution"
    # Prefer persistent labeling when semanage is available.
    if command -v semanage >/dev/null 2>&1; then
        sudo semanage fcontext -a -t bin_t "${RUNNER_DIR}(/.*)?" 2>/dev/null || \
            sudo semanage fcontext -m -t bin_t "${RUNNER_DIR}(/.*)?"
        sudo restorecon -Rv "${RUNNER_DIR}" >/dev/null
    else
        sudo find "${RUNNER_DIR}" -type f -perm /111 -exec chcon -t bin_t {} + || true
    fi
fi

echo "==> Configuring runner"
if [[ -f "${RUNNER_DIR}/.runner" && "${FORCE_RECONFIGURE}" -ne 1 ]]; then
    echo "INFO: runner is already configured in ${RUNNER_DIR} (use --force-reconfigure to replace)"
else
    if [[ -f "${RUNNER_DIR}/.runner" && "${FORCE_RECONFIGURE}" -eq 1 ]]; then
        echo "INFO: removing existing runner configuration"
        sudo -u "$RUNNER_USER" bash -lc "cd '${RUNNER_DIR}' && ./config.sh remove --token '${RUNNER_TOKEN}' || true"
    fi

    sudo -u "$RUNNER_USER" bash -lc \
        "cd '${RUNNER_DIR}' && ./config.sh \
        --unattended \
        --replace \
        --url '${RUNNER_URL}' \
        --token '${RUNNER_TOKEN}' \
        --name '${RUNNER_NAME}' \
        --runnergroup '${RUNNER_GROUP}' \
        --labels '${RUNNER_LABELS}' \
        --work '${RUNNER_WORK_DIR}'"
fi

echo "==> Writing runner environment"
sudo -u "$RUNNER_USER" bash -lc "cat > '${RUNNER_DIR}/.env' <<EOF
DOCKER_HOST=${docker_host}
EOF"

echo "==> Enabling linger and user podman socket"
sudo loginctl enable-linger "$RUNNER_USER"
if ! sudo -u "$RUNNER_USER" XDG_RUNTIME_DIR="/run/user/${runner_uid}" systemctl --user enable --now podman.socket; then
    echo "WARNING: could not enable user podman.socket automatically."
    echo "Run as ${RUNNER_USER}: systemctl --user enable --now podman.socket"
fi

echo "==> Installing and starting runner service"
if [[ -x "${RUNNER_DIR}/svc.sh" ]]; then
    if ! sudo bash -lc "cd '${RUNNER_DIR}' && ./svc.sh install '${RUNNER_USER}'"; then
        echo "INFO: service install may already exist; continuing"
    fi
    sudo bash -lc "cd '${RUNNER_DIR}' && ./svc.sh start"
    sudo bash -lc "cd '${RUNNER_DIR}' && ./svc.sh status" || true
else
    echo "ERROR: svc.sh not found in runner directory" >&2
    exit 1
fi

echo
echo "Runner configured successfully."
echo "Runner dir: ${RUNNER_DIR}"
echo "Runner name: ${RUNNER_NAME}"
echo "Runner url: ${RUNNER_URL}"
echo "Labels: self-hosted,Linux,${runner_arch},${RUNNER_LABELS}"
echo "DOCKER_HOST: ${docker_host}"
