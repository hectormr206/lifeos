#!/usr/bin/env bash
# Build the signed release APK and drop a timestamped copy next to it,
# so the newest build is always identifiable by name.
#
# After a successful build, this also PUBLISHES the APK to the LifeOS engine's
# self-hosted OTA update store (axi/scripts/publish-app-update.sh), so the
# sideloaded phone can self-update to it via GET /api/app/{manifest,download}.
# The publish step is best-effort: if the axi venv/script isn't present it just
# warns and the build still succeeds.
set -euo pipefail
cd "$(dirname "$0")/.."          # -> mobile/
MOBILE_DIR="$(pwd)"
REPO_ROOT="$(dirname "$MOBILE_DIR")"

# Auto-increment versionCode from the git commit count so every build is a
# strictly newer version — this is what lets the OTA self-update detect it.
BUILD_NUMBER="$(git -C "$REPO_ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
echo "→ build-number (versionCode): $BUILD_NUMBER"
flutter build apk --release --build-number="$BUILD_NUMBER"
OUT="build/app/outputs/flutter-apk"
TS="$(date +%Y%m%d-%H%M%S)"
NEW_APK="$OUT/app-release-$TS.apk"
cp "$OUT/app-release.apk" "$NEW_APK"
echo ""
echo "✅ APK más reciente: $NEW_APK"
ls -lh "$OUT"/app-release-*.apk 2>/dev/null | tail -5

# ── Publish to the engine's OTA update store (best-effort) ──────────────────
PUBLISH="$REPO_ROOT/axi/scripts/publish-app-update.sh"
VENV_PY="$REPO_ROOT/axi/.venv/bin/python"
if [[ -x "$PUBLISH" && -x "$VENV_PY" ]]; then
  # Release notes: git short SHA + commit subject (fallback to the timestamp).
  if ! NOTES="$(git -C "$REPO_ROOT" log -1 --format='%h %s' 2>/dev/null)" || [[ -z "$NOTES" ]]; then
    NOTES="release $TS"
  fi
  echo ""
  echo "→ Publicando actualización OTA al motor…"
  if "$PUBLISH" "$MOBILE_DIR/$NEW_APK" --notes "$NOTES"; then
    echo "✅ Publicado al motor (disponible para el teléfono emparejado)."
  else
    echo "⚠️  No se pudo publicar la actualización OTA (build OK de todos modos)." >&2
  fi
else
  echo ""
  echo "⚠️  publish-app-update.sh o el venv de axi no están disponibles;" >&2
  echo "    omitiendo la publicación OTA (build OK)." >&2
fi
