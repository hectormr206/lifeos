#!/bin/bash
#===============================================================================
# LifeOS Build Artifact - Full Pipeline
#===============================================================================
# Executes steps 0-3 from "Reconstruir imagen y generar ISO.md":
#   0) Remove previous image
#   1) Rebuild image from scratch (--no-cache)
#   2) Verify image baseline
#   3) Generate artifact with bootc-image-builder (iso/raw/qcow2/vmdk)
#
# Usage:
#   sudo ./scripts/build-iso.sh
#   sudo ./scripts/build-iso.sh --type raw --image localhost/lifeos:latest
#===============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()     { echo -e "${BLUE}[LifeOS]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

show_help() {
    cat << EOF
Usage: sudo ./scripts/build-iso.sh [OPTIONS]

Options:
  -t, --type TYPE          Artifact type: iso (default), raw, qcow2, vmdk
  -i, --image IMAGE        OCI image tag (default: localhost/lifeos:latest)
  -m, --install-mode MODE  Installer mode for ISO: interactive (default) or unattended
      --output-dir DIR     Output directory (default: ./output)
  -h, --help               Show this help

Examples:
  sudo ./scripts/build-iso.sh
  sudo ./scripts/build-iso.sh --type raw --image localhost/lifeos:latest
  LIFEOS_INSTALL_MODE=unattended sudo ./scripts/build-iso.sh --type iso
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

IMAGE_NAME="localhost/lifeos:latest"
BUILD_TYPE="iso"
INSTALL_MODE="${LIFEOS_INSTALL_MODE:-interactive}"
OUTPUT_DIR="${LIFEOS_OUTPUT_DIR:-${PROJECT_ROOT}/output}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--type)
            BUILD_TYPE="$2"
            shift 2
            ;;
        -i|--image)
            IMAGE_NAME="$2"
            shift 2
            ;;
        -m|--install-mode)
            INSTALL_MODE="$2"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

case "$BUILD_TYPE" in
    iso|raw|qcow2|vmdk) ;;
    *) error "Invalid --type: $BUILD_TYPE. Use iso, raw, qcow2 or vmdk." ;;
esac

case "$INSTALL_MODE" in
    interactive|unattended) ;;
    *) error "Invalid --install-mode: $INSTALL_MODE. Use interactive or unattended." ;;
esac

if [[ ! -f "$PROJECT_ROOT/image/Containerfile" ]]; then
    error "image/Containerfile not found. Run from the project root."
fi

if ! command -v podman >/dev/null 2>&1; then
    error "podman not found. Install podman first."
fi

if [[ $EUID -ne 0 ]]; then
    error "This script requires sudo/root."
fi

mkdir -p "$OUTPUT_DIR"
LOG_FILE="${LIFEOS_BUILD_LOG_FILE:-${OUTPUT_DIR}/build-${BUILD_TYPE}.log}"
LATEST_LOG_FILE="${OUTPUT_DIR}/build-iso.log"
mkdir -p "$(dirname "$LOG_FILE")"
: > "$LOG_FILE"
if [[ "$LOG_FILE" == "$LATEST_LOG_FILE" ]]; then
    exec > >(tee "$LOG_FILE") 2>&1
else
    : > "$LATEST_LOG_FILE"
    exec > >(tee "$LOG_FILE" "$LATEST_LOG_FILE") 2>&1
fi

trap 'status=$?; if [[ $status -ne 0 ]]; then echo -e "${RED}[ERROR]${NC} Build failed. See logs: ${LOG_FILE} and ${LATEST_LOG_FILE}"; else echo -e "${GREEN}[OK]${NC} Logs updated: ${LOG_FILE} and ${LATEST_LOG_FILE}"; fi' EXIT

echo -e "${CYAN}${BOLD}"
cat << 'BANNER'
   __    _ ____     ____  _____
  / /   (_) __/__  / __ \/ ___/
 / /   / / /_/ _ \/ / / /\__ \
/ /___/ / __/  __/ /_/ /___/ /
\____/_/_/  \___/\____//____/

  Build Artifact - Full Pipeline
BANNER
echo -e "${NC}"

START_TIME=$(date +%s)
BUILD_DATE="${BUILD_DATE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
VCS_REF="${VCS_REF:-$(git -C "$PROJECT_ROOT" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)}"

log "Configuration: type=$BUILD_TYPE image=$IMAGE_NAME install_mode=$INSTALL_MODE output=$OUTPUT_DIR"
echo

log "Step 0/3: Removing previous image (if present)..."
if podman image exists "$IMAGE_NAME" 2>/dev/null; then
    podman rmi -f "$IMAGE_NAME" 2>/dev/null || true
    success "Previous image removed"
else
    success "No previous image found"
fi
echo

log "Step 1/3: Rebuilding image from scratch..."
podman build \
    --no-cache \
    --build-arg "BUILD_DATE=${BUILD_DATE}" \
    --build-arg "VCS_REF=${VCS_REF}" \
    -t "$IMAGE_NAME" \
    -f "$PROJECT_ROOT/image/Containerfile" \
    "$PROJECT_ROOT"
success "Image built: $IMAGE_NAME"
echo

log "Step 2/3: Verifying image baseline..."

OS_ID=$(podman run --rm "$IMAGE_NAME" grep '^ID=' /usr/lib/os-release 2>/dev/null || echo "")
if echo "$OS_ID" | grep -q 'ID=fedora'; then
    success "os-release: $OS_ID"
else
    error "os-release missing ID=fedora (got: $OS_ID)"
fi

VARIANT=$(podman run --rm "$IMAGE_NAME" grep '^VARIANT_ID=' /usr/lib/os-release 2>/dev/null || echo "")
if echo "$VARIANT" | grep -q 'VARIANT_ID=lifeos'; then
    success "os-release: $VARIANT"
else
    warn "VARIANT_ID is not lifeos (got: $VARIANT)"
fi

LLAMA_PATH=$(podman run --rm "$IMAGE_NAME" which llama-server 2>/dev/null || echo "")
if [[ "$LLAMA_PATH" == "/usr/bin/llama-server" ]]; then
    success "llama-server: $LLAMA_PATH"
elif [[ -n "$LLAMA_PATH" ]]; then
    warn "llama-server found at $LLAMA_PATH (expected /usr/bin/llama-server)"
else
    error "llama-server not found in image"
fi

MODEL_CHECK=$(podman run --rm "$IMAGE_NAME" ls -lh /var/lib/lifeos/models/ 2>/dev/null || echo "")
if echo "$MODEL_CHECK" | grep -q '.gguf'; then
    success "AI model preinstalled"
else
    warn "No .gguf model found"
fi

LIFE_VER=$(podman run --rm "$IMAGE_NAME" life --version 2>/dev/null || echo "")
if [[ -n "$LIFE_VER" ]]; then
    success "CLI: $LIFE_VER"
else
    error "life CLI is not working in image"
fi

if podman run --rm "$IMAGE_NAME" docker --version >/dev/null 2>&1; then
    success "Docker compatibility CLI available"
else
    warn "docker CLI compatibility check failed"
fi

if podman run --rm "$IMAGE_NAME" podman-compose --version >/dev/null 2>&1; then
    success "podman-compose available"
else
    warn "podman-compose check failed"
fi

echo

log "Step 3/3: Generating ${BUILD_TYPE} artifact..."
chmod +x "$PROJECT_ROOT/scripts/generate-iso-simple.sh"
LIFEOS_OUTPUT_DIR="$OUTPUT_DIR" \
LIFEOS_INSTALL_MODE="$INSTALL_MODE" \
bash "$PROJECT_ROOT/scripts/generate-iso-simple.sh" \
    --type "$BUILD_TYPE" \
    --image "$IMAGE_NAME" \
    --install-mode "$INSTALL_MODE"
echo

case "$BUILD_TYPE" in
    iso) FINAL_FILE="$OUTPUT_DIR/lifeos-latest.iso" ;;
    raw) FINAL_FILE="$OUTPUT_DIR/lifeos-latest.raw" ;;
    qcow2) FINAL_FILE="$OUTPUT_DIR/lifeos-latest.qcow2" ;;
    vmdk) FINAL_FILE="$OUTPUT_DIR/lifeos-latest.vmdk" ;;
esac

if [[ ! -f "$FINAL_FILE" ]]; then
    error "Expected artifact not found: $FINAL_FILE"
fi

FINAL_SIZE=$(du -h "$FINAL_FILE" | cut -f1)
END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))
MINUTES=$(( ELAPSED / 60 ))
SECONDS=$(( ELAPSED % 60 ))

echo
echo -e "${GREEN}${BOLD}================================================================${NC}"
echo -e "${GREEN}${BOLD}  LifeOS ${BUILD_TYPE} ready${NC}"
echo -e "${GREEN}${BOLD}================================================================${NC}"
echo
echo -e "  ${BOLD}Artifact:${NC} $FINAL_FILE"
echo -e "  ${BOLD}Size:${NC}     $FINAL_SIZE"
echo -e "  ${BOLD}Time:${NC}     ${MINUTES}m ${SECONDS}s"
echo -e "  ${BOLD}Log:${NC}      $LOG_FILE"
if [[ "$LOG_FILE" != "$LATEST_LOG_FILE" ]]; then
    echo -e "  ${BOLD}Latest:${NC}   $LATEST_LOG_FILE"
fi
echo

if [[ "$BUILD_TYPE" == "iso" ]]; then
    echo -e "  ${BOLD}Next:${NC}"
    echo "  1. Create VM (Fedora 64-bit, 4GB RAM, 40GB disk, EFI)"
    echo "  2. Attach ISO as optical media"
    if [[ "$INSTALL_MODE" == "interactive" ]]; then
        echo "  3. In Anaconda, select target disk manually and install"
    else
        echo "  3. Install unattended (automatic partitioning)"
    fi
    echo "  4. After install, run: sudo life check"
    echo "     (user: lifeos / password: lifeos)"
fi
