#!/usr/bin/env bash
# Build the signed release APK and drop a timestamped copy next to it,
# so the newest build is always identifiable by name.
set -euo pipefail
cd "$(dirname "$0")/.."          # -> mobile/
flutter build apk --release
OUT="build/app/outputs/flutter-apk"
TS="$(date +%Y%m%d-%H%M%S)"
cp "$OUT/app-release.apk" "$OUT/app-release-$TS.apk"
echo ""
echo "✅ APK más reciente: $OUT/app-release-$TS.apk"
ls -lh "$OUT"/app-release-*.apk 2>/dev/null | tail -5
