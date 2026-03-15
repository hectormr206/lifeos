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
PRELOAD_MODEL_DIR="/usr/share/lifeos/models"
ENV_FILE="/etc/lifeos/llama-server.env"
REMOVED_MODELS_FILE="${MODEL_DIR}/.removed-models"

# Default model can be optionally preloaded in the image during build (see Containerfile).
# This script only downloads known heavy models when the configured model is missing
# and the user did not explicitly remove it.
DEFAULT_MODEL="Qwen3.5-4B-Q4_K_M.gguf"
DEFAULT_MODEL_URL="https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf"
DEFAULT_MMPROJ="Qwen3.5-4B-mmproj-F16.gguf"
DEFAULT_MMPROJ_URL="https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/mmproj-F16.gguf"

# Source env to get configured model
if [ -f "$ENV_FILE" ]; then
    . "$ENV_FILE"
fi

MODEL="${LIFEOS_AI_MODEL:-}"
MODEL_URL="$DEFAULT_MODEL_URL"
MMPROJ="${LIFEOS_AI_MMPROJ:-}"
MMPROJ_URL="$DEFAULT_MMPROJ_URL"
MODEL_PATH=""
MMPROJ_PATH=""

ensure_writable_model_dir() {
    local target=""

    mkdir -p "$(dirname "$MODEL_DIR")"

    if [ -L "$MODEL_DIR" ]; then
        target="$(readlink -f "$MODEL_DIR" || true)"
        if [ ! -w "$MODEL_DIR" ]; then
            echo "Model directory points to a read-only location (${target}); migrating to writable /var storage"
            rm -f "$MODEL_DIR"
            mkdir -p "$MODEL_DIR"
            chmod 755 "$MODEL_DIR"

            if [ -n "$target" ] && [ -d "$target" ]; then
                find "$target" -maxdepth 1 -type f -name "*.gguf" -exec cp -n {} "$MODEL_DIR"/ \;
            fi
        fi
    else
        mkdir -p "$MODEL_DIR"
    fi
}

set_env_value() {
    local key="$1"
    local value="$2"

    mkdir -p "$(dirname "$ENV_FILE")"
    touch "$ENV_FILE"

    if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
        sed -i "s#^${key}=.*#${key}=${value}#" "$ENV_FILE"
    else
        printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
    fi
}

clear_env_value() {
    local key="$1"

    if [ ! -f "$ENV_FILE" ]; then
        return
    fi

    sed -i "/^${key}=/d" "$ENV_FILE"
}

is_primary_model_candidate() {
    case "$1" in
        mmproj-*|*-mmproj-*|nomic-embed-*|whisper*|*embedding*)
            return 1
            ;;
        *.gguf)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

find_existing_primary_model() {
    find "$MODEL_DIR" -maxdepth 1 -type f -name "*.gguf" -printf '%f\n' 2>/dev/null | sort | while read -r candidate; do
        if is_primary_model_candidate "$candidate"; then
            printf '%s\n' "$candidate"
            break
        fi
    done
}

find_existing_primary_model_not_removed() {
    find "$MODEL_DIR" -maxdepth 1 -type f -name "*.gguf" -printf '%f\n' 2>/dev/null | sort | while read -r candidate; do
        if is_primary_model_candidate "$candidate" && ! is_removed_model "$candidate"; then
            printf '%s\n' "$candidate"
            break
        fi
    done
}

is_removed_model() {
    local candidate="$1"
    [ -f "$REMOVED_MODELS_FILE" ] && grep -Fxq "$candidate" "$REMOVED_MODELS_FILE"
}

resolve_model_assets() {
    local requested_mmproj="${LIFEOS_AI_MMPROJ:-}"

    case "$MODEL" in
        Qwen3.5-4B-Q4_K_M.gguf)
            MODEL_URL="https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf"
            MMPROJ_URL="https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/mmproj-F16.gguf"
            if [ -z "$requested_mmproj" ] || [ "$requested_mmproj" = "mmproj-F16.gguf" ]; then
                MMPROJ="Qwen3.5-4B-mmproj-F16.gguf"
            else
                MMPROJ="$requested_mmproj"
            fi
            ;;
        Qwen3.5-9B-Q4_K_M.gguf)
            MODEL_URL="https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-Q4_K_M.gguf"
            MMPROJ_URL="https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/main/mmproj-F16.gguf"
            if [ -z "$requested_mmproj" ] || [ "$requested_mmproj" = "mmproj-F16.gguf" ]; then
                MMPROJ="Qwen3.5-9B-mmproj-F16.gguf"
            else
                MMPROJ="$requested_mmproj"
            fi
            ;;
        Qwen3.5-27B-Q4_K_M.gguf)
            MODEL_URL="https://huggingface.co/unsloth/Qwen3.5-27B-GGUF/resolve/main/Qwen3.5-27B-Q4_K_M.gguf"
            MMPROJ_URL="https://huggingface.co/unsloth/Qwen3.5-27B-GGUF/resolve/main/mmproj-F16.gguf"
            if [ -z "$requested_mmproj" ] || [ "$requested_mmproj" = "mmproj-F16.gguf" ]; then
                MMPROJ="Qwen3.5-27B-mmproj-F16.gguf"
            else
                MMPROJ="$requested_mmproj"
            fi
            ;;
        *)
            MODEL_URL=""
            MMPROJ_URL=""
            if [ -z "$requested_mmproj" ]; then
                MMPROJ="$DEFAULT_MMPROJ"
            else
                MMPROJ="$requested_mmproj"
            fi
            ;;
    esac

    MODEL_PATH="$MODEL_DIR/$MODEL"
    MMPROJ_PATH="$MODEL_DIR/$MMPROJ"
}

adopt_legacy_mmproj() {
    local legacy_path="$MODEL_DIR/mmproj-F16.gguf"

    if [ "$MMPROJ" = "mmproj-F16.gguf" ]; then
        resolve_model_assets
    fi

    if [ "$MMPROJ" = "mmproj-F16.gguf" ]; then
        return
    fi

    if [ -f "$legacy_path" ] && [ ! -f "$MMPROJ_PATH" ]; then
        mv -f "$legacy_path" "$MMPROJ_PATH"
        echo "Adopted legacy vision projector as $MMPROJ"
    fi
}

seed_from_preload() {
    if [ ! -d "$PRELOAD_MODEL_DIR" ]; then
        return
    fi

    if [ ! -f "$MODEL_PATH" ] && [ -f "$PRELOAD_MODEL_DIR/$MODEL" ]; then
        cp -n "$PRELOAD_MODEL_DIR/$MODEL" "$MODEL_PATH"
        echo "Seeded model from image payload: $MODEL"
    fi

    if [ ! -f "$MMPROJ_PATH" ] && [ -f "$PRELOAD_MODEL_DIR/$MMPROJ" ]; then
        cp -n "$PRELOAD_MODEL_DIR/$MMPROJ" "$MMPROJ_PATH"
        echo "Seeded vision projector from image payload: $MMPROJ"
    elif [ ! -f "$MMPROJ_PATH" ] && [ -f "$PRELOAD_MODEL_DIR/mmproj-F16.gguf" ]; then
        cp -n "$PRELOAD_MODEL_DIR/mmproj-F16.gguf" "$MMPROJ_PATH"
        echo "Seeded legacy vision projector from image payload: $MMPROJ"
    fi
}

ensure_writable_model_dir
if [ -z "$MODEL" ]; then
    EXISTING=$(find_existing_primary_model_not_removed)
    if [ -n "$EXISTING" ]; then
        MODEL=$(basename "$EXISTING")
        echo "Using existing local model as default: $MODEL"
    else
        MODEL="$DEFAULT_MODEL"
    fi
fi

resolve_model_assets
adopt_legacy_mmproj
seed_from_preload

if [ ! -f "$MODEL_PATH" ] && is_removed_model "$MODEL"; then
    echo "Model $MODEL was removed by the user; skipping auto-download."
    FALLBACK_EXISTING=$(find_existing_primary_model_not_removed)
    if [ -n "$FALLBACK_EXISTING" ] && [ "$(basename "$FALLBACK_EXISTING")" != "$MODEL" ]; then
        MODEL=$(basename "$FALLBACK_EXISTING")
        echo "Using fallback local model: $MODEL"
        resolve_model_assets
        adopt_legacy_mmproj
        seed_from_preload
    else
        clear_env_value "LIFEOS_AI_MODEL"
        clear_env_value "LIFEOS_AI_MMPROJ"
        echo "No local fallback model available. Heavy-model runtime remains disabled."
        exit 0
    fi
fi

# If model already exists, check mmproj too
if [ -f "$MODEL_PATH" ]; then
    set_env_value "LIFEOS_AI_MODEL" "$MODEL"
    set_env_value "LIFEOS_AI_MMPROJ" "$MMPROJ"
    echo "Model $MODEL already present at $MODEL_PATH"
    if [ -f "$MMPROJ_PATH" ]; then
        echo "Vision projector $MMPROJ already present"
        exit 0
    fi
    # Model exists but mmproj missing — download it
    echo "Vision projector missing, downloading..."
    if [ -z "$MMPROJ_URL" ]; then
        echo "WARNING: No companion vision projector mapping for $MODEL. Visual features may be unavailable."
        exit 0
    fi
    if curl -fSL --retry 3 --connect-timeout 30 -o "$MMPROJ_PATH.tmp" "$MMPROJ_URL"; then
        mv "$MMPROJ_PATH.tmp" "$MMPROJ_PATH"
        echo "Vision projector downloaded: $MMPROJ"
    else
        echo "WARNING: Could not download vision projector. Visual features will not work."
        rm -f "$MMPROJ_PATH.tmp"
    fi
    exit 0
fi

# Check if any primary model exists (user may have placed a different one)
EXISTING=$(find_existing_primary_model_not_removed)
if [ -n "$EXISTING" ]; then
    echo "Found existing model: $EXISTING"
    BASENAME=$(basename "$EXISTING")
    MODEL="$BASENAME"
    resolve_model_assets
    set_env_value "LIFEOS_AI_MODEL" "$MODEL"
    set_env_value "LIFEOS_AI_MMPROJ" "$MMPROJ"
    exit 0
fi

if is_removed_model "$MODEL"; then
    echo "Configured model $MODEL was removed by the user; skipping auto-download."
    clear_env_value "LIFEOS_AI_MODEL"
    clear_env_value "LIFEOS_AI_MMPROJ"
    exit 0
fi

if [ -z "$MODEL_URL" ]; then
    echo "No auto-download mapping for model: $MODEL"
    exit 0
fi

echo "Downloading configured AI model: $MODEL"
echo "This may take several minutes..."

# Download model with retry
for attempt in 1 2 3; do
    if curl -fSL --retry 3 --connect-timeout 30 -o "$MODEL_DIR/$MODEL.tmp" "$MODEL_URL"; then
        mv "$MODEL_DIR/$MODEL.tmp" "$MODEL_DIR/$MODEL"
        echo "Model downloaded successfully: $MODEL"
        break
    fi
    echo "Download attempt $attempt failed, retrying..."
    sleep 5
done

# Download mmproj
if [ ! -f "$MMPROJ_PATH" ]; then
    echo "Downloading vision projector: $MMPROJ"
    if curl -fSL --retry 3 --connect-timeout 30 -o "$MMPROJ_PATH.tmp" "$MMPROJ_URL"; then
        mv "$MMPROJ_PATH.tmp" "$MMPROJ_PATH"
        echo "Vision projector downloaded: $MMPROJ"
    else
        echo "WARNING: Could not download vision projector."
        rm -f "$MMPROJ_PATH.tmp"
    fi
fi

if [ -f "$MODEL_PATH" ]; then
    set_env_value "LIFEOS_AI_MODEL" "$MODEL"
    set_env_value "LIFEOS_AI_MMPROJ" "$MMPROJ"
fi

if [ ! -f "$MODEL_PATH" ]; then
    echo "WARNING: Could not download AI model. llama-server will not serve requests until a model is available."
    echo "Download manually: curl -L -o $MODEL_DIR/$MODEL $MODEL_URL"
    rm -f "$MODEL_DIR/$MODEL.tmp"
    clear_env_value "LIFEOS_AI_MODEL"
    clear_env_value "LIFEOS_AI_MMPROJ"
fi

# Exit 0 so llama-server.service is not blocked
exit 0
