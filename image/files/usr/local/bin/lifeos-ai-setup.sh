#!/bin/bash
# LifeOS AI Setup - downloads default model if not present
set -euo pipefail

MODEL_DIR="/var/lib/lifeos/models"
ENV_FILE="/etc/lifeos/llama-server.env"
DEFAULT_MODEL="qwen3-8b-q4_k_m.gguf"
DEFAULT_MODEL_URL="https://huggingface.co/Qwen/Qwen3-8B-GGUF/resolve/main/qwen3-8b-q4_k_m.gguf"
SMALL_MODEL="qwen3-1.7b-q4_k_m.gguf"
SMALL_MODEL_URL="https://huggingface.co/Qwen/Qwen3-1.7B-GGUF/resolve/main/qwen3-1.7b-q4_k_m.gguf"

# Source env to get configured model
if [ -f "$ENV_FILE" ]; then
    . "$ENV_FILE"
fi

MODEL="${LIFEOS_AI_MODEL:-$DEFAULT_MODEL}"
MODEL_PATH="$MODEL_DIR/$MODEL"

# If model already exists, nothing to do
if [ -f "$MODEL_PATH" ]; then
    echo "Model $MODEL already present at $MODEL_PATH"
    exit 0
fi

# Check if any model exists
EXISTING=$(find "$MODEL_DIR" -name "*.gguf" -type f 2>/dev/null | head -n 1)
if [ -n "$EXISTING" ]; then
    echo "Found existing model: $EXISTING"
    BASENAME=$(basename "$EXISTING")
    sed -i "s/^LIFEOS_AI_MODEL=.*/LIFEOS_AI_MODEL=$BASENAME/" "$ENV_FILE"
    exit 0
fi

echo "Downloading default AI model: $MODEL"
echo "This may take several minutes..."

# Detect available RAM to choose model size
TOTAL_RAM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 8192)

if [ "$TOTAL_RAM_MB" -lt 6144 ]; then
    echo "Low memory detected (${TOTAL_RAM_MB}MB). Using smaller model."
    MODEL="$SMALL_MODEL"
    MODEL_URL="$SMALL_MODEL_URL"
    sed -i "s/^LIFEOS_AI_MODEL=.*/LIFEOS_AI_MODEL=$MODEL/" "$ENV_FILE"
else
    MODEL_URL="$DEFAULT_MODEL_URL"
fi

mkdir -p "$MODEL_DIR"

# Download with retry
for attempt in 1 2 3; do
    if curl -fSL --retry 3 --connect-timeout 30 -o "$MODEL_DIR/$MODEL.tmp" "$MODEL_URL"; then
        mv "$MODEL_DIR/$MODEL.tmp" "$MODEL_DIR/$MODEL"
        echo "Model downloaded successfully: $MODEL"
        exit 0
    fi
    echo "Download attempt $attempt failed, retrying..."
    sleep 5
done

echo "WARNING: Could not download AI model. AI service will not start until a model is available."
echo "Download manually: curl -L -o $MODEL_DIR/$MODEL $MODEL_URL"
rm -f "$MODEL_DIR/$MODEL.tmp"
exit 1
