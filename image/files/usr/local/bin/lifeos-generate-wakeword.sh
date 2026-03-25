#!/bin/bash
# lifeos-generate-wakeword.sh — Generate a rustpotter .rpw wake word model
# from synthetic TTS samples using espeak-ng.
#
# This script is called during image build AND at first-boot to ensure
# the wake word model exists. It generates multiple voice variants of
# "Axi" using different espeak voices and speeds to create a robust model.
#
# Usage: lifeos-generate-wakeword.sh [output_path]

set -euo pipefail

OUTPUT="${1:-/var/lib/lifeos/models/rustpotter/axi.rpw}"
SAMPLES_DIR="$(mktemp -d /tmp/lifeos-wakeword-samples.XXXXXX)"
TRAIN_BIN="${LIFEOS_TRAIN_WAKEWORD_BIN:-lifeos-train-wakeword}"

cleanup() { rm -rf "$SAMPLES_DIR"; }
trap cleanup EXIT

echo "[wakeword] Generating synthetic wake word samples..."

# Generate diverse samples with different voices, speeds, and pitches.
# espeak-ng produces 16-bit PCM WAV which rustpotter expects.
SAMPLE_NUM=0
generate() {
    local voice="$1" speed="$2" pitch="$3" text="$4"
    SAMPLE_NUM=$((SAMPLE_NUM + 1))
    local file="${SAMPLES_DIR}/axi-$(printf '%02d' $SAMPLE_NUM).wav"
    espeak-ng -v "$voice" -s "$speed" -p "$pitch" -w "$file" "$text" 2>/dev/null
    echo "  sample ${SAMPLE_NUM}: voice=${voice} speed=${speed} pitch=${pitch}"
}

# Spanish voices with "Axi" and "Aksi" phonetic variants
generate es       140 50 "Aksi"
generate es       160 50 "Aksi"
generate es       120 50 "Aksi"
generate es       140 70 "Aksi"
generate es       140 30 "Aksi"
generate es-la    140 50 "Aksi"
generate es-la    160 40 "Aksi"
generate es-la    120 60 "Aksi"

# English voices for accent diversity
generate en       140 50 "Axi"
generate en       160 50 "Axi"
generate en-us    140 50 "Axi"
generate en-us    120 60 "Axi"

echo "[wakeword] Generated ${SAMPLE_NUM} samples in ${SAMPLES_DIR}"

# Ensure output directory exists
mkdir -p "$(dirname "$OUTPUT")"

# Build the .rpw model
echo "[wakeword] Training rustpotter model..."
"$TRAIN_BIN" --name axi --output "$OUTPUT" "${SAMPLES_DIR}"/axi-*.wav

echo "[wakeword] Model ready at: ${OUTPUT}"
ls -la "$OUTPUT"
