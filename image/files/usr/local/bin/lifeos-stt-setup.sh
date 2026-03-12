#!/bin/bash
# LifeOS STT setup hook for whisper.cpp runtime.
set -euo pipefail

STT_BIN=""
for candidate in /usr/bin/whisper-cli /usr/local/bin/whisper-cli /usr/bin/whisper /usr/bin/whisper-cpp; do
    if [ -x "$candidate" ]; then
        STT_BIN="$candidate"
        break
    fi
done

if [ -z "$STT_BIN" ]; then
    echo "WARNING: whisper STT binary not found (expected whisper-cli/whisper)."
    exit 0
fi

MODEL_DIR="/var/lib/lifeos/models/whisper"
PRELOAD_DIR="/usr/share/lifeos/models/whisper"
DEFAULT_MODEL="ggml-base.bin"

mkdir -p "$MODEL_DIR"

if [ ! -f "$MODEL_DIR/$DEFAULT_MODEL" ] && [ -f "$PRELOAD_DIR/$DEFAULT_MODEL" ]; then
    cp -n "$PRELOAD_DIR/$DEFAULT_MODEL" "$MODEL_DIR/$DEFAULT_MODEL"
    echo "Seeded STT model from image payload: $DEFAULT_MODEL"
fi

echo "whisper binary ready: $STT_BIN"
if [ -f "$MODEL_DIR/$DEFAULT_MODEL" ]; then
    echo "stt model ready: $MODEL_DIR/$DEFAULT_MODEL"
else
    echo "WARNING: default STT model not found at $MODEL_DIR/$DEFAULT_MODEL"
fi

exit 0
