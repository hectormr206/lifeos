#!/usr/bin/env bash
# publish-to-vps.sh — one command to ship a LifeOS mobile update.
#
# Builds the signed release APK with the public-OTA config baked in, uploads it
# to the self-hosted update server on the VPS (behind the key-gated public URL),
# regenerates the manifest, repoints current.apk, and verifies the live endpoint
# now serves the new versionCode. Paired phones then auto-update on their own.
#
# Secrets (URL, access key, VPS target) live in tools/ota-publish.env, which is
# gitignored and never committed. Usage:
#     ./tools/publish-to-vps.sh ["release notes"]
set -euo pipefail
cd "$(dirname "$0")/.."          # -> mobile/
MOBILE_DIR="$(pwd)"
REPO_ROOT="$(dirname "$MOBILE_DIR")"

# ── Load secrets ────────────────────────────────────────────────────────────
ENV_FILE="$MOBILE_DIR/tools/ota-publish.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: falta $ENV_FILE" >&2
  echo "       Necesita: UPDATE_BASE_URL, UPDATE_ACCESS_KEY, VPS_SSH, VPS_DIR" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"
: "${UPDATE_BASE_URL:?falta UPDATE_BASE_URL en ota-publish.env}"
: "${UPDATE_ACCESS_KEY:?falta UPDATE_ACCESS_KEY en ota-publish.env}"
: "${VPS_SSH:=vps}"
: "${VPS_DIR:=lifeos-updates}"
KEY_HEADER="X-LifeOS-Update-Key"

# ── Build ───────────────────────────────────────────────────────────────────
# versionCode = git commit count, so every published build is strictly newer;
# that monotonic bump is exactly what lets the phone detect the update.
BUILD_NUMBER="$(git -C "$REPO_ROOT" rev-list --count HEAD)"
NOTES="${1:-$(git -C "$REPO_ROOT" log -1 --format='%h %s' 2>/dev/null || echo "release $BUILD_NUMBER")}"
echo "→ Building release APK (versionCode $BUILD_NUMBER)…"
flutter build apk --release \
  --build-number="$BUILD_NUMBER" \
  --dart-define=UPDATE_BASE_URL="$UPDATE_BASE_URL" \
  --dart-define=UPDATE_ACCESS_KEY="$UPDATE_ACCESS_KEY" \
  --dart-define=STT_MODEL_BASE_URL="${STT_MODEL_BASE_URL:-$UPDATE_BASE_URL/stt}" \
  --dart-define=TTS_MODEL_BASE_URL="${TTS_MODEL_BASE_URL:-$UPDATE_BASE_URL/tts}" \
  --dart-define=EMBED_MODEL_BASE_URL="${EMBED_MODEL_BASE_URL:-$UPDATE_BASE_URL/embed}" \
  --dart-define=BRAIN_MODEL_BASE_URL="${BRAIN_MODEL_BASE_URL:-$UPDATE_BASE_URL/model}"

APK="$MOBILE_DIR/build/app/outputs/flutter-apk/app-release.apk"
[[ -f "$APK" ]] || { echo "ERROR: no se generó $APK" >&2; exit 1; }

# ── Metadata (versionCode/name from the APK itself via aapt) ─────────────────
AAPT="$(fd -t f '^aapt$' "$HOME/Android/Sdk/build-tools" 2>/dev/null | sort -V | tail -1)"
[[ -x "$AAPT" ]] || { echo "ERROR: no encontré aapt en Android SDK build-tools" >&2; exit 1; }
BADGING="$("$AAPT" dump badging "$APK")"
VC="$(echo "$BADGING" | rg -o "versionCode='([0-9]+)'" -r '$1' | head -1)"
VN="$(echo "$BADGING" | rg -o "versionName='([^']+)'" -r '$1' | head -1)"
SHA="$(sha256sum "$APK" | cut -d' ' -f1)"
SZ="$(stat -c%s "$APK")"
FN="lifeos-${VN}-${VC}.apk"
LOCAL_COPY="$MOBILE_DIR/build/app/outputs/flutter-apk/$FN"
cp "$APK" "$LOCAL_COPY"
echo "→ Empaquetado: $FN  (versionCode $VC · $(( SZ / 1024 / 1024 )) MB · sha ${SHA:0:12}…)"

# ── Manifest ────────────────────────────────────────────────────────────────
MANIFEST="$(mktemp)"
PUBLISHED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
VC="$VC" VN="$VN" FN="$FN" SHA="$SHA" SZ="$SZ" NOTES="$NOTES" AT="$PUBLISHED_AT" \
python3 - > "$MANIFEST" <<'PY'
import json, os
print(json.dumps({
    "versionCode": int(os.environ["VC"]),
    "versionName": os.environ["VN"],
    "apkFilename": os.environ["FN"],
    "sha256":      os.environ["SHA"],
    "sizeBytes":   int(os.environ["SZ"]),
    "notes":       os.environ["NOTES"],
    "publishedAt": os.environ["AT"],
}, ensure_ascii=False, indent=2))
PY

# ── Upload + repoint current.apk on the VPS ─────────────────────────────────
echo "→ Subiendo a $VPS_SSH:$VPS_DIR/ …"
scp -o ConnectTimeout=20 "$LOCAL_COPY" "$VPS_SSH:$VPS_DIR/$FN"
scp -o ConnectTimeout=20 "$MANIFEST"  "$VPS_SSH:$VPS_DIR/manifest.json"
# current.apk is a symlink the server serves at /download; repoint it atomically.
ssh "$VPS_SSH" "cd '$VPS_DIR' && ln -sfn '$FN' current.apk"
rm -f "$MANIFEST"

# ── Verify the live endpoint now advertises this version ─────────────────────
echo "→ Verificando endpoint público…"
LIVE_VC="$(curl -fsS --max-time 25 -H "$KEY_HEADER: $UPDATE_ACCESS_KEY" \
  "$UPDATE_BASE_URL/manifest" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("versionCode","?"))' 2>/dev/null || echo '?')"

echo ""
if [[ "$LIVE_VC" == "$VC" ]]; then
  echo "✅ PUBLICADO: versionCode $VC ($VN) — vivo en $UPDATE_BASE_URL"
  echo "   Los celulares emparejados recibirán la actualización sola."
else
  echo "⚠️  Subido, pero el endpoint reporta versionCode '$LIVE_VC' (esperaba $VC)." >&2
  echo "   Revisá el serving del VPS (current.apk / manifest.json)." >&2
  exit 1
fi
