#!/usr/bin/env bash
# publish-linux-to-vps.sh — one command to ship a LifeOS **desktop** update.
#
# Builds the release Linux bundle with the public-OTA config baked in, packs it
# into a tarball together with the icon, the systemd units and the installer
# itself, computes sha256/size, writes the Linux manifest, uploads everything
# to the self-hosted update server under linux/<arch>/, and verifies the live
# endpoint now serves the new versionCode. Installed laptops then auto-update
# on their own via lifeos-updater.timer.
#
# Mirrors publish-to-vps.sh (same env file, same versionCode semantics, same
# manifest-last upload ordering, same live-endpoint verification). The one
# structural difference: Android ships a single signed APK, desktop ships a
# tarball that must also carry its own installer and units, because the
# installer is what runs as root on the target machine.
#
# Secrets (URL, access key, VPS target) live in tools/ota-publish.env, which is
# gitignored and never committed. Usage:
#     ./tools/publish-linux-to-vps.sh ["release notes"]
set -euo pipefail
# Resolve ourselves BEFORE the cd: after it, a relative "$0" no longer points
# at this file, which is exactly how --help broke the first time.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$SELF")/.."       # -> mobile/
MOBILE_DIR="$(pwd)"
REPO_ROOT="$(dirname "$MOBILE_DIR")"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  # Print the header comment block, stopping at the first line of real code, so
  # the help text cannot drift out of sync with a hardcoded line number.
  sed -n '2,/^[^#]/p' "$SELF" | sed '$d' | sed 's/^# \{0,1\}//'
  exit 0
fi

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

# Desktop releases are per-architecture: the tarball contains compiled .so
# files, so publishing an x64 build under a shared path would hand an arm64
# laptop something it cannot execute.
case "$(uname -m)" in
  x86_64|amd64)  ARCH="x64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) echo "ERROR: arquitectura no soportada: $(uname -m)" >&2; exit 1 ;;
esac
BASE_URL="${LINUX_UPDATE_BASE_URL:-$UPDATE_BASE_URL/linux}"
REMOTE_DIR="$VPS_DIR/linux/$ARCH"

# ── Build ───────────────────────────────────────────────────────────────────
# versionCode = git commit count, exactly as publish-to-vps.sh does it, so a
# phone and a laptop built from the same commit report the same version and
# every published build is strictly newer than the last.
BUILD_NUMBER="$(git -C "$REPO_ROOT" rev-list --count HEAD)"
VN="$(rg -o '^version:\s*([0-9]+\.[0-9]+\.[0-9]+)' -r '$1' "$MOBILE_DIR/pubspec.yaml" | head -1)"
[[ -n "$VN" ]] || { echo "ERROR: no pude leer 'version:' de pubspec.yaml" >&2; exit 1; }
NOTES="${1:-$(git -C "$REPO_ROOT" log -1 --format='%h %s' 2>/dev/null || echo "release $BUILD_NUMBER")}"

echo "→ Building release Linux bundle ($ARCH, versionCode $BUILD_NUMBER)…"
flutter build linux --release \
  --build-number="$BUILD_NUMBER" \
  --dart-define=UPDATE_BASE_URL="$UPDATE_BASE_URL" \
  --dart-define=UPDATE_ACCESS_KEY="$UPDATE_ACCESS_KEY" \
  --dart-define=STT_MODEL_BASE_URL="${STT_MODEL_BASE_URL:-$UPDATE_BASE_URL/stt}" \
  --dart-define=TTS_MODEL_BASE_URL="${TTS_MODEL_BASE_URL:-$UPDATE_BASE_URL/tts}" \
  --dart-define=EMBED_MODEL_BASE_URL="${EMBED_MODEL_BASE_URL:-$UPDATE_BASE_URL/embed}" \
  --dart-define=BRAIN_MODEL_BASE_URL="${BRAIN_MODEL_BASE_URL:-$UPDATE_BASE_URL/model}"

BUNDLE="$MOBILE_DIR/build/linux/x64/release/bundle"
[[ "$ARCH" == "arm64" ]] && BUNDLE="$MOBILE_DIR/build/linux/arm64/release/bundle"
[[ -x "$BUNDLE/lifeos" ]] || { echo "ERROR: no se generó $BUNDLE/lifeos" >&2; exit 1; }

# ── Stage the payload ───────────────────────────────────────────────────────
# Everything the target machine needs ships inside the ONE artifact whose
# sha256 the installer verifies: the app, the icon, the systemd units and the
# installer script itself. Nothing is fetched separately at install time, so
# nothing can be swapped underneath the checksum.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
NAME="lifeos-linux-${ARCH}-${VN}-${BUILD_NUMBER}"
ROOT="$STAGE/$NAME"
mkdir -p "$ROOT/share/systemd" "$ROOT/bin"

cp -a "$BUNDLE" "$ROOT/bundle"
cp "$MOBILE_DIR/assets/branding/axi-512.png" "$ROOT/share/lifeos.png"
for unit in lifeos-updater.service lifeos-updater.timer lifeos-updater.path; do
  src="$MOBILE_DIR/tools/systemd/$unit"
  [[ -f "$src" ]] || { echo "ERROR: falta $src" >&2; exit 1; }
  cp "$src" "$ROOT/share/systemd/$unit"
done
install -m 0755 "$MOBILE_DIR/tools/install-linux.sh" "$ROOT/bin/install-linux.sh"
printf '%s %s %s\n' "$VN" "$BUILD_NUMBER" "$ARCH" > "$ROOT/VERSION"

TARBALL="$STAGE/${NAME}.tar.gz"
echo "→ Empaquetando $NAME.tar.gz …"
# --sort=name + fixed mtime so an unchanged build produces an identical
# tarball, which makes "did anything actually change?" answerable by sha256.
tar --sort=name --mtime="@$(git -C "$REPO_ROOT" log -1 --format=%ct)" \
    --owner=0 --group=0 --numeric-owner \
    -czf "$TARBALL" -C "$STAGE" "$NAME"

FN="${NAME}.tar.gz"
SHA="$(sha256sum "$TARBALL" | cut -d' ' -f1)"
SZ="$(stat -c%s "$TARBALL")"
echo "→ Empaquetado: $FN  (versionCode $BUILD_NUMBER · $(( SZ / 1024 / 1024 )) MB · sha ${SHA:0:12}…)"

# ── Manifest ────────────────────────────────────────────────────────────────
# Field names mirror the APK manifest (versionCode/versionName/sha256/
# sizeBytes/notes/publishedAt); 'apkFilename' becomes 'filename' and 'arch' is
# added, because a desktop client must refuse a tarball built for another CPU.
MANIFEST="$(mktemp)"
PUBLISHED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
VC="$BUILD_NUMBER" VN="$VN" FN="$FN" SHA="$SHA" SZ="$SZ" ARCH="$ARCH" \
NOTES="$NOTES" AT="$PUBLISHED_AT" \
python3 - > "$MANIFEST" <<'PY'
import json, os
print(json.dumps({
    "versionCode": int(os.environ["VC"]),
    "versionName": os.environ["VN"],
    "filename":    os.environ["FN"],
    "sha256":      os.environ["SHA"],
    "sizeBytes":   int(os.environ["SZ"]),
    "arch":        os.environ["ARCH"],
    "platform":    "linux",
    "notes":       os.environ["NOTES"],
    "publishedAt": os.environ["AT"],
}, ensure_ascii=False, indent=2))
PY

# ── Upload (payload first, manifest LAST so a half-upload never advertises) ──
if [[ "$VPS_SSH" == "local" || -d "$HOME/$VPS_DIR" ]]; then
  echo "→ Copiando directamente a $HOME/$REMOTE_DIR/ …"
  mkdir -p "$HOME/$REMOTE_DIR"
  cp "$TARBALL" "$HOME/$REMOTE_DIR/$FN"
  install -m 0755 "$MOBILE_DIR/tools/install-linux.sh" "$HOME/$VPS_DIR/linux/install-linux.sh"
  # install -m 0644, not cp: the manifest is written to a mktemp file whose
  # 0600 mode cp faithfully preserves, and nginx runs as another user — the
  # tarball served fine while the manifest 403'd, which reads like a routing
  # bug and is not one.
  install -m 0644 "$MANIFEST" "$HOME/$REMOTE_DIR/manifest.json"
else
  echo "→ Subiendo a $VPS_SSH:$REMOTE_DIR/ …"
  # shellcheck disable=SC2029  # $REMOTE_DIR is ours and must expand locally.
  ssh "$VPS_SSH" "mkdir -p '$REMOTE_DIR'"
  scp -o ConnectTimeout=20 "$TARBALL" "$VPS_SSH:$REMOTE_DIR/$FN"
  # The installer lives one level up: it is arch-independent and it is what the
  # user curls. Uploaded before the manifest for the same reason as the tarball.
  scp -o ConnectTimeout=20 "$MOBILE_DIR/tools/install-linux.sh" \
      "$VPS_SSH:$VPS_DIR/linux/install-linux.sh"
  scp -o ConnectTimeout=20 "$MANIFEST" "$VPS_SSH:$REMOTE_DIR/manifest.json"
  # scp preserves the temp file's 0600 too — see the note on the local branch.
  ssh -o ConnectTimeout=20 "$VPS_SSH" "chmod 0644 '$REMOTE_DIR/manifest.json'"
fi
rm -f "$MANIFEST"

# ── Verify the live endpoint now advertises this version ─────────────────────
echo "→ Verificando endpoint público…"
LIVE_VC="$(curl -fsS --max-time 25 -H "$KEY_HEADER: $UPDATE_ACCESS_KEY" \
  "$BASE_URL/$ARCH/manifest.json" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("versionCode","?"))' 2>/dev/null || echo '?')"

# The manifest being live is not the same as the tarball being downloadable —
# that is the failure that would strand every laptop mid-update. Check the
# artifact really is served, without pulling 150 MB.
LIVE_TARBALL_CODE="$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 25 -r 0-0 \
  -H "$KEY_HEADER: $UPDATE_ACCESS_KEY" "$BASE_URL/$ARCH/$FN" 2>/dev/null || echo '000')"

echo ""
if [[ "$LIVE_VC" == "$BUILD_NUMBER" && ( "$LIVE_TARBALL_CODE" == "206" || "$LIVE_TARBALL_CODE" == "200" ) ]]; then
  echo "✅ PUBLICADO: versionCode $BUILD_NUMBER ($VN, $ARCH) — vivo en $BASE_URL/$ARCH"
  echo "   Las laptops instaladas se actualizarán solas (lifeos-updater.timer)."
  echo ""
  echo "   Instalación nueva:"
  echo "     curl -fsSL $BASE_URL/install-linux.sh \\"
  echo "       | sudo sh -s -- --base-url $UPDATE_BASE_URL --key <UPDATE_ACCESS_KEY>"
else
  echo "⚠️  Subido, pero la verificación falló:" >&2
  echo "     manifest versionCode = '$LIVE_VC' (esperaba $BUILD_NUMBER)" >&2
  echo "     tarball HTTP         = '$LIVE_TARBALL_CODE' (esperaba 200/206)" >&2
  echo "   Revisá el serving del VPS ($REMOTE_DIR/)." >&2
  exit 1
fi
