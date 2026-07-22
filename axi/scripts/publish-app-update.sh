#!/usr/bin/env bash
# publish-app-update — publish a LifeOS/Axi release APK for OTA self-update.
#
# Reads versionCode/versionName straight out of the APK binary (via aapt), so
# what's published always matches the actual build — never pubspec. Copies the
# APK under a stable name into the app-updates dir and (re)writes manifest.json,
# which the dashboard serves at GET /api/app/{manifest,download}.
#
# Updates dir (in precedence order):
#   --updates-dir <path>  >  $LIFEOS_APP_UPDATES_DIR  >  $XDG_STATE_HOME/axi/app-updates
#   (default ~/.local/state/axi/app-updates)
#
# Usage:
#   publish-app-update <apk-path> [--notes "release notes"] [--updates-dir <path>]
#
# Intended to be called from the mobile build (mobile/tools/build-release-apk.sh)
# right after a successful release build, e.g.:
#   axi/scripts/publish-app-update.sh build/app/outputs/.../app-release.apk --notes "$NOTES"
set -euo pipefail
exec "$(dirname "$(dirname "$(readlink -f "$0")")")/.venv/bin/python" -m axi.app_updates "$@"
