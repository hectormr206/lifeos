#!/bin/bash
# LifeOS STT setup hook for whisper.cpp runtime.
#
# Phase 6b: whisper models no longer ship pre-baked in the bootc image at
# /usr/share/lifeos/models/whisper. They live at runtime under
# /var/lib/lifeos/models/whisper/. This script ensures the default model
# is present on first boot:
#   1. If a preload dir from a legacy bootc exists, copy from there.
#   2. Else, download from HuggingFace ggml repo when
#      LIFEOS_AI_AUTO_MANAGE_MODELS=true.
#   3. Else, exit clean (lifeosd falls back to non-STT operation).
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
DEFAULT_MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${DEFAULT_MODEL}"

mkdir -p "$MODEL_DIR"

# Path 1 — legacy preload dir (rolled back from a bootc deployment that still
# bundled the models). Copy what's there, idempotent.
if [ -d "$PRELOAD_DIR" ]; then
    find "$PRELOAD_DIR" -maxdepth 1 -type f -name 'ggml-*.bin' -print0 | while IFS= read -r -d '' model; do
        cp -n "$model" "$MODEL_DIR/"
    done
fi

# Path 2 — download if missing AND auto-manage is on. Same opt-in flag the
# chat / embedding model setups respect.
DEST="$MODEL_DIR/$DEFAULT_MODEL"
if [ ! -f "$DEST" ]; then
    AUTO_MANAGE_MODELS="${LIFEOS_AI_AUTO_MANAGE_MODELS:-false}"
    case "$AUTO_MANAGE_MODELS" in
        1|true|TRUE|yes|YES|on|ON)
            echo "[lifeos-stt-setup] downloading $DEFAULT_MODEL (~150MB)..."
            TMP="$DEST.tmp"
            if curl -fSL --retry 3 --connect-timeout 60 -o "$TMP" "$DEFAULT_MODEL_URL"; then
                mv "$TMP" "$DEST"
                echo "[lifeos-stt-setup] downloaded: $DEST"
            else
                rm -f "$TMP"
                echo "[lifeos-stt-setup] download failed — STT will be unavailable until network recovers and the service re-runs."
                # Exit 0 so the oneshot ExecStart unit doesn't park in the
                # `failed` state on first-boot timeouts. lifeosd's STT path
                # checks for the model file at runtime and gracefully
                # falls back to no-transcription when absent.
                exit 0
            fi
            ;;
        *)
            echo "[lifeos-stt-setup] LIFEOS_AI_AUTO_MANAGE_MODELS=$AUTO_MANAGE_MODELS — STT model not present and auto-download is opt-in. Set the env var or drop ggml-base.bin into $MODEL_DIR/ manually."
            # Exit 0 so the oneshot ExecStart unit reports success and
            # doesn't appear in `systemctl --failed`. The user is opted out
            # of STT model management; this is the documented behaviour.
            exit 0
            ;;
    esac
fi

echo "whisper binary ready: $STT_BIN"
if [ -n "$STREAM_BIN" ]; then
    echo "whisper stream binary ready: $STREAM_BIN"
else
    echo "WARNING: whisper-stream binary not found"
fi
if [ -f "$DEST" ]; then
    echo "stt model ready: $DEST"
else
    echo "WARNING: default STT model not found at $DEST — STT calls will fall back gracefully"
fi

exit 0
