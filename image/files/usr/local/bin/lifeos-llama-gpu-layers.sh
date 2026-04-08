#!/bin/bash
# lifeos-llama-gpu-layers.sh — Set CPU/Game Guard override env for llama-server.
#
# Usage: lifeos-llama-gpu-layers.sh <layers>
#   layers = 0   → CPU only (offload to RAM)
#   layers = -1  → All layers on GPU (restore)
#
# This script can be used for manual recovery; lifeosd now writes the same
# override file directly under /var/lib/lifeos.

set -euo pipefail

LAYERS="${1:?Usage: $0 <gpu_layers>}"
OVERRIDE_DIR="/var/lib/lifeos"
OVERRIDE_ENV="${OVERRIDE_DIR}/llama-server-game-guard.env"
LEGACY_DROPIN_DIR="/etc/systemd/system/llama-server.service.d"
LEGACY_DROPIN_FILE="${LEGACY_DROPIN_DIR}/99-game-guard-gpu-layers.conf"

mkdir -p "$OVERRIDE_DIR"

if [ "$LAYERS" = "-1" ]; then
    # Restore: remove override so the default env file value is used
    rm -f "$OVERRIDE_ENV" "$LEGACY_DROPIN_FILE"
    echo "[game_guard] Removed GPU layers override — restoring default"
else
    # Write override env file (loaded after the main env file by llama-server.service)
    echo "LIFEOS_AI_GPU_LAYERS=${LAYERS}" > "$OVERRIDE_ENV"
    rm -f "$LEGACY_DROPIN_FILE"
    echo "[game_guard] Set GPU layers to ${LAYERS} via runtime env override"
fi

systemctl restart llama-server.service
echo "[game_guard] llama-server restarted with GPU layers=${LAYERS}"
