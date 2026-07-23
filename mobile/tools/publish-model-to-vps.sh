#!/usr/bin/env bash
# publish-model-to-vps.sh — one command to ship a new BRAIN model (OTA).
#
# Takes a .litertlm weights file + a versionCode, computes sha256/size, writes
# the brain-model manifest.json, uploads BOTH to the VPS's public model path
# (flat: <base>/manifest.json + <base>/<filename>), and verifies the live
# endpoint now advertises the new versionCode. Phones then show
# "Hay un nuevo modelo disponible" in the Modelo local screen (user-tapped
# download — never automatic; it's 2.6GB).
#
# Mirrors publish-to-vps.sh. Config lives in tools/ota-publish.env (gitignored):
#   UPDATE_BASE_URL  (the model path defaults to $UPDATE_BASE_URL/model,
#                     override with BRAIN_MODEL_BASE_URL)
#   VPS_SSH, VPS_DIR (model files land in $VPS_DIR/model/)
#
# Usage:
#     ./tools/publish-model-to-vps.sh <path/to/model.litertlm> <versionCode> ["notes"]
set -euo pipefail
cd "$(dirname "$0")/.."          # -> mobile/
MOBILE_DIR="$(pwd)"

MODEL_PATH="${1:?uso: publish-model-to-vps.sh <model.litertlm> <versionCode> [\"notas\"]}"
VERSION_CODE="${2:?falta el versionCode (entero, estrictamente creciente)}"
NOTES="${3:-modelo v$VERSION_CODE}"

[[ -f "$MODEL_PATH" ]] || { echo "ERROR: no existe $MODEL_PATH" >&2; exit 1; }
[[ "$VERSION_CODE" =~ ^[0-9]+$ ]] || { echo "ERROR: versionCode debe ser un entero" >&2; exit 1; }

# Stable internal identity — must match the app's kBrainModelName/-FileName
# (lib/features/local_model/domain/brain_model_manifest.dart).
MODEL_NAME="gemma-4-E2B-it"
FILENAME="gemma-4-E2B-it.litertlm"

# ── Load config ──────────────────────────────────────────────────────────────
ENV_FILE="$MOBILE_DIR/tools/ota-publish.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: falta $ENV_FILE" >&2
  echo "       Necesita: UPDATE_BASE_URL, VPS_SSH, VPS_DIR" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"
: "${UPDATE_BASE_URL:?falta UPDATE_BASE_URL en ota-publish.env}"
: "${VPS_SSH:=vps}"
: "${VPS_DIR:=lifeos-updates}"
BASE_URL="${BRAIN_MODEL_BASE_URL:-$UPDATE_BASE_URL/model}"
REMOTE_DIR="$VPS_DIR/model"

# ── Metadata ─────────────────────────────────────────────────────────────────
SHA="$(sha256sum "$MODEL_PATH" | cut -d' ' -f1)"
SZ="$(stat -c%s "$MODEL_PATH")"
echo "→ Empaquetado: $FILENAME  (versionCode $VERSION_CODE · $(( SZ / 1024 / 1024 )) MB · sha ${SHA:0:12}…)"

# ── Manifest ─────────────────────────────────────────────────────────────────
MANIFEST="$(mktemp)"
PUBLISHED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
MODEL_NAME="$MODEL_NAME" VC="$VERSION_CODE" FN="$FILENAME" SHA="$SHA" SZ="$SZ" \
NOTES="$NOTES" AT="$PUBLISHED_AT" \
python3 - > "$MANIFEST" <<'PY'
import json, os
print(json.dumps({
    "modelName":   os.environ["MODEL_NAME"],
    "versionCode": int(os.environ["VC"]),
    "filename":    os.environ["FN"],
    "sha256":      os.environ["SHA"],
    "sizeBytes":   int(os.environ["SZ"]),
    "notes":       os.environ["NOTES"],
    "publishedAt": os.environ["AT"],
}, ensure_ascii=False, indent=2))
PY

# ── Upload (weights first, manifest LAST so a half-upload never advertises) ──
echo "→ Subiendo a $VPS_SSH:$REMOTE_DIR/ …"
ssh "$VPS_SSH" "mkdir -p '$REMOTE_DIR'"
scp -o ConnectTimeout=20 "$MODEL_PATH" "$VPS_SSH:$REMOTE_DIR/$FILENAME"
scp -o ConnectTimeout=20 "$MANIFEST"   "$VPS_SSH:$REMOTE_DIR/manifest.json"
rm -f "$MANIFEST"

# ── Verify the live endpoint now advertises this version ─────────────────────
echo "→ Verificando endpoint público…"
LIVE_VC="$(curl -fsS --max-time 25 "$BASE_URL/manifest.json" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("versionCode","?"))' 2>/dev/null || echo '?')"

echo ""
if [[ "$LIVE_VC" == "$VERSION_CODE" ]]; then
  echo "✅ PUBLICADO: $MODEL_NAME versionCode $VERSION_CODE — vivo en $BASE_URL"
  echo "   Los celulares mostrarán \"Hay un nuevo modelo disponible\" (descarga a un tap)."
else
  echo "⚠️  Subido, pero el endpoint reporta versionCode '$LIVE_VC' (esperaba $VERSION_CODE)." >&2
  echo "   Revisá el serving del VPS ($REMOTE_DIR/manifest.json)." >&2
  exit 1
fi
