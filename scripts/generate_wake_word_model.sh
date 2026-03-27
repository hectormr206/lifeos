#!/usr/bin/env bash
# generate_wake_word_model.sh — Generate base wake word model for "axi" using
# Piper TTS synthetic samples + rustpotter-cli training.
#
# Usage:
#   bash scripts/generate_wake_word_model.sh
#
# Requirements:
#   - piper-tts (or piper) CLI installed
#   - A Piper ONNX voice model (auto-detected or set PIPER_MODEL)
#   - Optional: rustpotter-cli for training the .rpw model

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$REPO_ROOT/image/files/usr/share/lifeos/models/rustpotter"
TEMP_DIR="$(mktemp -d /tmp/lifeos-wake-word-XXXXXX)"
WORD="axi"

# Cleanup on exit
trap 'rm -rf "$TEMP_DIR"' EXIT

# ── Detect Piper binary ──────────────────────────────────────────────────

PIPER_BIN=""
for candidate in piper-tts piper; do
    if command -v "$candidate" &>/dev/null; then
        PIPER_BIN="$candidate"
        break
    fi
done

if [[ -z "$PIPER_BIN" ]]; then
    echo "ERROR: piper-tts not found. Install it with:"
    echo "  pip install piper-tts"
    echo "  # or download from https://github.com/rhasspy/piper/releases"
    exit 1
fi

echo "Using Piper binary: $PIPER_BIN"

# ── Detect Piper voice model ─────────────────────────────────────────────

if [[ -z "${PIPER_MODEL:-}" ]]; then
    # Search common locations for a Spanish voice model
    for candidate in \
        /usr/share/piper-voices/es/es_ES/davefx/medium/es_ES-davefx-medium.onnx \
        /usr/share/piper-voices/es/es_MX/claude/high/es_MX-claude-high.onnx \
        "$HOME/.local/share/piper-voices/"es*.onnx \
        /var/lib/lifeos/models/piper/*.onnx \
        "$HOME/.local/share/piper/voices/"*.onnx; do
        if [[ -f "$candidate" ]]; then
            PIPER_MODEL="$candidate"
            break
        fi
    done
fi

if [[ -z "${PIPER_MODEL:-}" ]]; then
    echo "ERROR: No Piper voice model found. Set PIPER_MODEL=/path/to/model.onnx"
    echo "  Download a model from: https://github.com/rhasspy/piper/blob/master/VOICES.md"
    exit 1
fi

echo "Using Piper model: $PIPER_MODEL"

# ── Generate samples at different speeds ──────────────────────────────────

# length_scale < 1.0 = faster speech, > 1.0 = slower speech
LENGTH_SCALES=(0.8 0.9 1.0 1.1 1.2)
SAMPLE_INDEX=0

echo ""
echo "Generating $WORD samples at different speeds..."

for scale in "${LENGTH_SCALES[@]}"; do
    for iteration in 1 2; do
        SAMPLE_INDEX=$((SAMPLE_INDEX + 1))
        OUTFILE="$TEMP_DIR/${WORD}_sample_$(printf '%02d' $SAMPLE_INDEX)_scale${scale}.wav"

        echo "  Sample $SAMPLE_INDEX: length_scale=$scale (iteration $iteration)"
        echo "$WORD" | "$PIPER_BIN" \
            --model "$PIPER_MODEL" \
            --length-scale "$scale" \
            --output_file "$OUTFILE" \
            2>/dev/null || {
            echo "  WARNING: Failed to generate sample $SAMPLE_INDEX, skipping"
            continue
        }

        if [[ -f "$OUTFILE" ]]; then
            echo "    -> $(du -h "$OUTFILE" | cut -f1) written"
        fi
    done
done

TOTAL_SAMPLES=$(find "$TEMP_DIR" -name "*.wav" | wc -l)
echo ""
echo "Generated $TOTAL_SAMPLES samples in $TEMP_DIR"

if [[ "$TOTAL_SAMPLES" -eq 0 ]]; then
    echo "ERROR: No samples were generated. Check Piper installation."
    exit 1
fi

# ── Train with rustpotter-cli if available ────────────────────────────────

RUSTPOTTER_CLI=""
for candidate in rustpotter-cli rustpotter; do
    if command -v "$candidate" &>/dev/null; then
        RUSTPOTTER_CLI="$candidate"
        break
    fi
done

if [[ -n "$RUSTPOTTER_CLI" ]]; then
    echo ""
    echo "Training wake word model with: $RUSTPOTTER_CLI"

    mkdir -p "$OUTPUT_DIR"
    MODEL_OUTPUT="$OUTPUT_DIR/axi.rpw"

    # Build the list of WAV files for training
    WAV_FILES=()
    while IFS= read -r f; do
        WAV_FILES+=("$f")
    done < <(find "$TEMP_DIR" -name "*.wav" -type f | sort)

    # rustpotter-cli train expects: rustpotter-cli train <output> <wav1> <wav2> ...
    "$RUSTPOTTER_CLI" train "$MODEL_OUTPUT" "${WAV_FILES[@]}" && {
        echo ""
        echo "Wake word model trained successfully!"
        echo "  Output: $MODEL_OUTPUT"
        echo "  Size:   $(du -h "$MODEL_OUTPUT" | cut -f1)"
        echo ""
        echo "The model will be included in the next ISO build."
    } || {
        echo ""
        echo "WARNING: rustpotter-cli training failed."
        echo "The WAV samples are available for manual training."
        echo ""
        echo "Manual training command:"
        echo "  rustpotter-cli train $MODEL_OUTPUT ${WAV_FILES[*]}"
    }
else
    echo ""
    echo "rustpotter-cli not found. Samples generated but model NOT trained."
    echo ""
    echo "To install rustpotter-cli:"
    echo "  cargo install rustpotter-cli"
    echo ""
    echo "Then train manually:"
    echo "  mkdir -p $OUTPUT_DIR"
    echo "  rustpotter-cli train $OUTPUT_DIR/axi.rpw $TEMP_DIR/*.wav"
    echo ""
    echo "Sample files (copy before exit):"
    ls -la "$TEMP_DIR"/*.wav 2>/dev/null || true

    # Copy samples to a persistent location so they survive the temp cleanup
    PERSISTENT_SAMPLES="$REPO_ROOT/image/files/usr/share/lifeos/models/rustpotter/samples"
    mkdir -p "$PERSISTENT_SAMPLES"
    cp "$TEMP_DIR"/*.wav "$PERSISTENT_SAMPLES/" 2>/dev/null || true
    echo ""
    echo "Samples copied to: $PERSISTENT_SAMPLES"
fi
