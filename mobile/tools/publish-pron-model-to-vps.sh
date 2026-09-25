#!/usr/bin/env bash
# publish-pron-model-to-vps.sh — put the phone model (ZIPA) on the model server.
#
# The English "sounds to practise" need ZIPA-small CR-CTC int8 (71 MB). The app
# downloads it on first use from $UPDATE_BASE_URL/pron and accepts it only if
# its size and SHA-256 are EXACTLY the ones pinned in
# lib/features/english/data/pron_model.dart (the file that was measured).
#
# This script fetches both files from Hugging Face at a pinned revision,
# refuses to go on unless they match those pins, uploads them under the names
# the app asks for, and checks the public endpoint serves them. Run it once;
# re-running is harmless.
#
# Config: tools/ota-publish.env (gitignored), as publish-model-to-vps.sh:
#   UPDATE_BASE_URL  (the path defaults to $UPDATE_BASE_URL/pron,
#                     override with PRON_MODEL_BASE_URL)
#   VPS_SSH, VPS_DIR (files land in $VPS_DIR/pron/)
#
# Usage:
#     ./tools/publish-pron-model-to-vps.sh
set -euo pipefail
cd "$(dirname "$0")/.."          # -> mobile/
MOBILE_DIR="$(pwd)"

# anyspeech/zipa-small-crctc-500k, the ONNX export of the Apache-2.0 weights
# of anyspeech/zipa-cr-s (see assets/english/NOTICE.md).
HF_REPO="anyspeech/zipa-small-crctc-500k"
HF_REVISION="a97a19eab1e5b2263ade7922ba97bf737dd418db"
USER_AGENT="LifeOS/1.0 (https://github.com/hectormr206/lifeos)"

# remote name in HF | name the app asks for | sha256 | bytes  (pron_model.dart)
FILES=(
  "model.int8.onnx|zipa-small-crctc-500k.int8.onnx|d0e28b68164e8b1fbd6105100c01798828aa0855000ce9bbbd1a2cec233adf13|70677672"
  "tokens.txt|zipa-small-crctc-500k.tokens.txt|f8e042a0c9130532b22d03ec7cae2f75a23fbec70c450c31a8efb51787b2b8fe|769"
)

# Guard: the pins here must be the pins in the app.
for entry in "${FILES[@]}"; do
  IFS='|' read -r _ name sha _ <<<"$entry"
  grep -q "$name" lib/features/english/data/pron_model.dart &&
    grep -q "$sha" lib/features/english/data/pron_model.dart || {
    echo "ERROR: $name / $sha no coincide con pron_model.dart" >&2
    exit 1
  }
done

ENV_FILE="$MOBILE_DIR/tools/ota-publish.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: falta $ENV_FILE (UPDATE_BASE_URL, VPS_SSH, VPS_DIR)" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"
: "${UPDATE_BASE_URL:?falta UPDATE_BASE_URL en ota-publish.env}"
: "${VPS_SSH:=vps}"
: "${VPS_DIR:=lifeos-updates}"
BASE_URL="${PRON_MODEL_BASE_URL:-$UPDATE_BASE_URL/pron}"
REMOTE_DIR="$VPS_DIR/pron"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── Fetch and verify ─────────────────────────────────────────────────────────
for entry in "${FILES[@]}"; do
  IFS='|' read -r remote name sha bytes <<<"$entry"
  echo "→ Descargando $remote ($HF_REPO@${HF_REVISION:0:8})…"
  curl -fsSL -A "$USER_AGENT" -o "$WORK/$name" \
    "https://huggingface.co/$HF_REPO/resolve/$HF_REVISION/$remote"
  got_sha="$(sha256sum "$WORK/$name" | cut -d' ' -f1)"
  got_bytes="$(stat -c%s "$WORK/$name")"
  if [[ "$got_sha" != "$sha" || "$got_bytes" != "$bytes" ]]; then
    echo "ERROR: $remote no es el archivo medido ($got_bytes bytes, sha ${got_sha:0:12}…)" >&2
    exit 1
  fi
done

# ── Upload (model first, tokens last) ────────────────────────────────────────
echo "→ Subiendo a $VPS_SSH:$REMOTE_DIR/ …"
ssh "$VPS_SSH" "mkdir -p '$REMOTE_DIR'"
for entry in "${FILES[@]}"; do
  IFS='|' read -r _ name _ _ <<<"$entry"
  scp -o ConnectTimeout=20 "$WORK/$name" "$VPS_SSH:$REMOTE_DIR/$name"
done

# ── Verify the public endpoint serves exactly these bytes ────────────────────
echo "→ Verificando endpoint público…"
for entry in "${FILES[@]}"; do
  IFS='|' read -r _ name sha _ <<<"$entry"
  live="$(curl -fsS --max-time 300 -A "$USER_AGENT" "$BASE_URL/$name" | sha256sum | cut -d' ' -f1)"
  if [[ "$live" != "$sha" ]]; then
    echo "⚠️  $BASE_URL/$name no sirve el archivo esperado (sha ${live:0:12}…)" >&2
    exit 1
  fi
done
echo "✅ PUBLICADO: modelo de fonemas en $BASE_URL"
