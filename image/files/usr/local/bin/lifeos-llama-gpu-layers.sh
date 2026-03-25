#!/bin/bash
# lifeos-llama-gpu-layers.sh — Set GPU layers for llama-server and restart it.
# Called by lifeosd game_guard to offload LLM from VRAM to RAM when a game is detected.
#
# Usage: lifeos-llama-gpu-layers.sh <layers>
#   layers = 0   → CPU only (offload to RAM)
#   layers = -1  → All layers on GPU (restore)
#
# This script must run as root (via polkit or sudoers).

set -euo pipefail

LAYERS="${1:?Usage: $0 <gpu_layers>}"
OVERRIDE_DIR="/etc/systemd/system/llama-server.service.d"
OVERRIDE_FILE="${OVERRIDE_DIR}/99-game-guard-gpu-layers.conf"

mkdir -p "$OVERRIDE_DIR"

OVERRIDE_ENV="/etc/lifeos/llama-server-game-guard.env"

if [ "$LAYERS" = "-1" ]; then
    # Restore: remove override so the default env file value is used
    rm -f "$OVERRIDE_FILE" "$OVERRIDE_ENV"
    echo "[game_guard] Removed GPU layers override — restoring default"
else
    # Write override env file (EnvironmentFile processed AFTER the main one, so it wins)
    echo "LIFEOS_AI_GPU_LAYERS=${LAYERS}" > "$OVERRIDE_ENV"
    # Drop-in adds the override env file AFTER the main EnvironmentFile
    cat > "$OVERRIDE_FILE" <<EOF
[Service]
EnvironmentFile=-${OVERRIDE_ENV}
EOF
    echo "[game_guard] Set GPU layers to ${LAYERS} via env override"
fi

systemctl daemon-reload
systemctl restart llama-server.service
echo "[game_guard] llama-server restarted with GPU layers=${LAYERS}"
