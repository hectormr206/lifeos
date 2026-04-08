#!/bin/bash
# LifeOS Semantic Embeddings Setup
#
# Ensures the nomic-embed-text-v1.5 GGUF model is present so the
# llama-embeddings.service can serve real semantic embeddings on port 8083.
#
# This is a best-effort setup: if the download fails (offline boot, mirror
# down, etc.) the script exits 0 without writing the env file. The systemd
# unit's ConditionPathExists then prevents llama-server from starting in a
# bad state, and `MemoryPlaneManager` falls back to the chat-model
# embeddings (port 8082) or, ultimately, the deterministic hash fallback.
#
# Re-running this script (manually or via the unit's ExecStartPre) is
# idempotent: the model is downloaded only when missing.
set -euo pipefail

MODEL_DIR="/var/lib/lifeos/models"
ENV_FILE="/etc/lifeos/llama-embeddings.env"

# Pinned to v1.5 f16. Dimensions = 768 — must match the SQLite schema in
# memory_plane.rs (vec0(embedding FLOAT[768])).
EMBED_MODEL="nomic-embed-text-v1.5.f16.gguf"
EMBED_MODEL_URL="https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF/resolve/main/nomic-embed-text-v1.5.f16.gguf"

mkdir -p "$MODEL_DIR"
mkdir -p "$(dirname "$ENV_FILE")"

set_env_value() {
    local key="$1"
    local value="$2"
    touch "$ENV_FILE"
    if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
        sed -i "s#^${key}=.*#${key}=${value}#" "$ENV_FILE"
    else
        printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
    fi
}

EMBED_PATH="$MODEL_DIR/$EMBED_MODEL"

if [ -f "$EMBED_PATH" ]; then
    echo "[lifeos-embeddings-setup] model already present: $EMBED_PATH"
    set_env_value "LIFEOS_EMBED_MODEL" "$EMBED_MODEL"
    exit 0
fi

# Honour the same opt-out flag as the chat model setup.
AUTO_MANAGE_MODELS="${LIFEOS_AI_AUTO_MANAGE_MODELS:-false}"
case "$AUTO_MANAGE_MODELS" in
    1|true|TRUE|yes|YES|on|ON) ;;
    *)
        echo "[lifeos-embeddings-setup] LIFEOS_AI_AUTO_MANAGE_MODELS=$AUTO_MANAGE_MODELS — skipping download"
        exit 0
        ;;
esac

echo "[lifeos-embeddings-setup] downloading $EMBED_MODEL (~84MB)..."
TMP_PATH="$EMBED_PATH.tmp"
if curl -fSL --retry 3 --connect-timeout 30 -o "$TMP_PATH" "$EMBED_MODEL_URL"; then
    mv "$TMP_PATH" "$EMBED_PATH"
    echo "[lifeos-embeddings-setup] downloaded $EMBED_MODEL"
    set_env_value "LIFEOS_EMBED_MODEL" "$EMBED_MODEL"
else
    echo "[lifeos-embeddings-setup] WARNING: download failed; semantic embeddings will fall back to chat model or hash"
    rm -f "$TMP_PATH"
fi

# Always exit 0 — failure to download must not block the systemd unit; the
# MemoryPlaneManager handles missing embeddings gracefully.
exit 0
