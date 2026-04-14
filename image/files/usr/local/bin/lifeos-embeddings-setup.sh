#!/bin/bash
# LifeOS Semantic Embeddings Setup
#
# Ensures the nomic-embed-text-v1.5 GGUF model is present so the
# llama-embeddings.service can serve real semantic embeddings on port 8083.
#
# Called as ExecCondition by llama-embeddings.service. Exit code contract:
#   0       → model ready, start the service (llama-server will run)
#   1-254   → skip cleanly (systemd considers the unit successful, no failure)
#   255     → hard failure (reported to systemd as failed)
#
# With this contract, a missing model + LIFEOS_AI_AUTO_MANAGE_MODELS=false
# is a clean skip — MemoryPlaneManager then falls back to hash embedding
# without polluting the journal with "Failed Units: 1".
#
# Re-running is idempotent: the model is downloaded only when missing.
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
        exit 1
        ;;
esac

echo "[lifeos-embeddings-setup] downloading $EMBED_MODEL (~84MB)..."
TMP_PATH="$EMBED_PATH.tmp"
if curl -fSL --retry 3 --connect-timeout 30 -o "$TMP_PATH" "$EMBED_MODEL_URL"; then
    mv "$TMP_PATH" "$EMBED_PATH"
    echo "[lifeos-embeddings-setup] downloaded $EMBED_MODEL"
    set_env_value "LIFEOS_EMBED_MODEL" "$EMBED_MODEL"
    exit 0
else
    echo "[lifeos-embeddings-setup] WARNING: download failed; semantic embeddings will fall back to hash"
    rm -f "$TMP_PATH"
    exit 1
fi
