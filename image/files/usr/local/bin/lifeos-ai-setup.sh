#!/bin/bash
# LifeOS AI Setup - ensures llama-server binary is reachable and downloads model if not present
set -euo pipefail

# --- Verify llama-server binary is reachable ---
# On bootc systems /usr is immutable at runtime, so we cannot create symlinks.
# The binary should be at /usr/sbin/llama-server (set up at build time).
LLAMA_BIN=""
for p in /usr/sbin/llama-server /usr/bin/llama-server /usr/local/bin/llama-server; do
    if [ -x "$p" ]; then
        LLAMA_BIN="$p"
        break
    fi
done
if [ -z "$LLAMA_BIN" ]; then
    echo "ERROR: llama-server binary not found at /usr/sbin or /usr/bin"
    exit 0
fi
echo "llama-server binary: $LLAMA_BIN"

MODEL_DIR="/var/lib/lifeos/models"
ENV_FILE="/etc/lifeos/llama-server.env"

# Default model is pre-bundled in the image during build (see Containerfile).
# This script only downloads if the configured model is missing (e.g. user changed it).
DEFAULT_MODEL="Qwen3.5-4B-Q4_K_M.gguf"
DEFAULT_MODEL_URL="https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf"
DEFAULT_MMPROJ="mmproj-F16.gguf"
DEFAULT_MMPROJ_URL="https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/mmproj-F16.gguf"

# Source env to get configured model
if [ -f "$ENV_FILE" ]; then
    . "$ENV_FILE"
fi

MODEL="${LIFEOS_AI_MODEL:-$DEFAULT_MODEL}"
MODEL_PATH="$MODEL_DIR/$MODEL"
MMPROJ="${LIFEOS_AI_MMPROJ:-$DEFAULT_MMPROJ}"
MMPROJ_PATH="$MODEL_DIR/$MMPROJ"

# If model already exists, check mmproj too
if [ -f "$MODEL_PATH" ]; then
    echo "Model $MODEL already present at $MODEL_PATH"
    if [ -f "$MMPROJ_PATH" ]; then
        echo "Vision projector $MMPROJ already present"
        exit 0
    fi
    # Model exists but mmproj missing — download it
    echo "Vision projector missing, downloading..."
    if curl -fSL --retry 3 --connect-timeout 30 -o "$MMPROJ_PATH.tmp" "$DEFAULT_MMPROJ_URL"; then
        mv "$MMPROJ_PATH.tmp" "$MMPROJ_PATH"
        echo "Vision projector downloaded: $MMPROJ"
    else
        echo "WARNING: Could not download vision projector. Visual features will not work."
        rm -f "$MMPROJ_PATH.tmp"
    fi
    exit 0
fi

# Check if any model exists (user may have placed a different one)
EXISTING=$(find "$MODEL_DIR" -name "*.gguf" ! -name "mmproj-*" -type f 2>/dev/null | head -n 1)
if [ -n "$EXISTING" ]; then
    echo "Found existing model: $EXISTING"
    BASENAME=$(basename "$EXISTING")
    sed -i "s/^LIFEOS_AI_MODEL=.*/LIFEOS_AI_MODEL=$BASENAME/" "$ENV_FILE"
    exit 0
fi

echo "Downloading default AI model: $MODEL (~2.74GB)"
echo "This may take several minutes..."

mkdir -p "$(dirname "$MODEL_DIR")"
if [ ! -e "$MODEL_DIR" ]; then
    mkdir -p "$MODEL_DIR"
fi

# Download model with retry
for attempt in 1 2 3; do
    if curl -fSL --retry 3 --connect-timeout 30 -o "$MODEL_DIR/$MODEL.tmp" "$DEFAULT_MODEL_URL"; then
        mv "$MODEL_DIR/$MODEL.tmp" "$MODEL_DIR/$MODEL"
        echo "Model downloaded successfully: $MODEL"
        break
    fi
    echo "Download attempt $attempt failed, retrying..."
    sleep 5
done

# Download mmproj
if [ ! -f "$MMPROJ_PATH" ]; then
    echo "Downloading vision projector: $MMPROJ (~672MB)"
    if curl -fSL --retry 3 --connect-timeout 30 -o "$MMPROJ_PATH.tmp" "$DEFAULT_MMPROJ_URL"; then
        mv "$MMPROJ_PATH.tmp" "$MMPROJ_PATH"
        echo "Vision projector downloaded: $MMPROJ"
    else
        echo "WARNING: Could not download vision projector."
        rm -f "$MMPROJ_PATH.tmp"
    fi
fi

if [ ! -f "$MODEL_PATH" ]; then
    echo "WARNING: Could not download AI model. llama-server will not serve requests until a model is available."
    echo "Download manually: curl -L -o $MODEL_DIR/$MODEL $DEFAULT_MODEL_URL"
    rm -f "$MODEL_DIR/$MODEL.tmp"
fi

# Exit 0 so llama-server.service is not blocked
exit 0
