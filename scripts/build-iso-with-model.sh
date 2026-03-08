#!/usr/bin/env bash
# Build LifeOS artifact with prebundled AI model (large image).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_ROOT"

echo "[LifeOS] Building ISO/artifact WITH preloaded model (LIFEOS_PRELOAD_MODEL=true)"
echo "[LifeOS] This path downloads multi-GB model assets and takes longer."

LIFEOS_PRELOAD_MODEL=true bash "$SCRIPT_DIR/build-iso.sh" "$@"
