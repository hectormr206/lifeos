#!/bin/bash
# LifeOS STT setup hook for whisper.cpp runtime.
set -euo pipefail

STT_BIN=""
STREAM_BIN=""
for candidate in /usr/bin/whisper-cli /usr/local/bin/whisper-cli /usr/bin/whisper /usr/bin/whisper-cpp; do
    if [ -x "$candidate" ]; then
        STT_BIN="$candidate"
        break
    fi
done

for candidate in /usr/bin/whisper-stream /usr/local/bin/whisper-stream; do
    if [ -x "$candidate" ]; then
        STREAM_BIN="$candidate"
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

if [ -d "$PRELOAD_DIR" ]; then
    find "$PRELOAD_DIR" -maxdepth 1 -type f -name 'ggml-*.bin' -print0 | while IFS= read -r -d '' model; do
        cp -n "$model" "$MODEL_DIR/"
    done
fi

echo "whisper binary ready: $STT_BIN"
if [ -n "$STREAM_BIN" ]; then
    echo "whisper stream binary ready: $STREAM_BIN"
else
    echo "WARNING: whisper-stream binary not found"
fi
if [ -f "$MODEL_DIR/$DEFAULT_MODEL" ]; then
    echo "stt model ready: $MODEL_DIR/$DEFAULT_MODEL"
else
    echo "WARNING: default STT model not found at $MODEL_DIR/$DEFAULT_MODEL"
fi

exit 0
