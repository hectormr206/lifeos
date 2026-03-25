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

if [ "$LAYERS" = "-1" ]; then
    # Restore: remove override so the default env file value is used
    rm -f "$OVERRIDE_FILE"
    echo "[game_guard] Removed GPU layers override — restoring default"
else
    # Override: set specific GPU layers value
    cat > "$OVERRIDE_FILE" <<EOF
[Service]
Environment=LIFEOS_AI_GPU_LAYERS=${LAYERS}
EOF
    echo "[game_guard] Set GPU layers to ${LAYERS} via systemd drop-in"
fi

systemctl daemon-reload
systemctl restart llama-server.service
echo "[game_guard] llama-server restarted with GPU layers=${LAYERS}"
