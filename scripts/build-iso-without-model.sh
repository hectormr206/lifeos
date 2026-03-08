#!/usr/bin/env bash
# Build LifeOS artifact without prebundled AI model (lighter/faster image).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_ROOT"

echo "[LifeOS] Building ISO/artifact WITHOUT preloaded model (LIFEOS_PRELOAD_MODEL=false)"

LIFEOS_PRELOAD_MODEL=false bash "$SCRIPT_DIR/build-iso.sh" "$@"
