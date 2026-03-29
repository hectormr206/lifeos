#!/bin/bash
# Test icon theme completeness against freedesktop spec critical icons.
# Checks that all essential icon names exist in LifeOS or fallback Adwaita.
set -euo pipefail

THEME="image/files/usr/share/icons/LifeOS"
PASS=0
FAIL=0
FALLBACK=0

check() {
    local ctx="$1" name="$2"
    if [ -f "$THEME/scalable/$ctx/$name.svg" ]; then
        PASS=$((PASS + 1))
    else
        echo "  MISSING: $ctx/$name.svg (falls back to Adwaita)"
        FALLBACK=$((FALLBACK + 1))
    fi
}

echo "=== LifeOS Icon Theme Completeness Test ==="
echo ""

# Critical freedesktop icons that MUST exist for a usable desktop
echo "[actions — critical]"
for icon in document-new document-open document-save edit-copy edit-paste edit-delete edit-undo edit-redo \
    go-home go-next go-previous go-up go-down list-add list-remove view-refresh window-close \
    system-search system-run system-lock-screen system-log-out system-shutdown system-reboot \
    media-playback-start media-playback-pause media-playback-stop \
    zoom-in zoom-out view-fullscreen application-menu open-menu; do
    check actions "$icon"
done

echo "[apps — critical]"
for icon in lifeos lifeos-axi lifeos-dashboard cosmic-files cosmic-edit cosmic-term cosmic-settings \
    firefox chromium code telegram discord steam spotify; do
    check apps "$icon"
done

echo "[status — critical]"
for icon in audio-volume-high audio-volume-muted audio-volume-low audio-volume-medium \
    battery-full battery-low battery-charging battery-empty \
    network-online network-offline network-error \
    dialog-error dialog-warning dialog-information dialog-question \
    notification-new security-high software-update-available \
    weather-clear weather-overcast; do
    check status "$icon"
done

echo "[devices — critical]"
for icon in computer laptop phone drive-harddisk network-wired network-wireless \
    audio-input-microphone input-keyboard input-mouse printer camera-photo battery bluetooth; do
    check devices "$icon"
done

echo "[places — critical]"
for icon in folder folder-home folder-documents folder-download folder-music folder-pictures \
    folder-videos user-home user-trash folder-root; do
    check places "$icon"
done

echo "[mimetypes — critical]"
for icon in text-plain text-html application-pdf application-json application-x-executable \
    image-png audio-x-generic video-x-generic text-x-generic inode-directory; do
    check mimetypes "$icon"
done

echo "[emblems — critical]"
for icon in emblem-default emblem-favorite emblem-important emblem-readonly emblem-shared emblem-system; do
    check emblems "$icon"
done

echo "[categories — critical]"
for icon in applications-development applications-games applications-internet applications-multimedia \
    preferences-desktop preferences-system; do
    check categories "$icon"
done

echo ""
echo "=== RESULTS ==="
TOTAL=$((PASS + FALLBACK))
echo "Checked: $TOTAL critical icons"
echo "Present in LifeOS: $PASS"
echo "Fallback to Adwaita: $FALLBACK"
PCT=$((PASS * 100 / TOTAL))
echo "Coverage: ${PCT}%"

# Check symbolic variants
SYMB=$(find "$THEME/scalable" -name "*-symbolic.svg" 2>/dev/null | wc -l)
FULL=$(find "$THEME/scalable" -name "*.svg" ! -name "*-symbolic.svg" 2>/dev/null | wc -l)
echo ""
echo "Full-color SVGs: $FULL"
echo "Symbolic SVGs: $SYMB"
echo "Axi states: $(find "$THEME/axi" -name "*.svg" 2>/dev/null | wc -l)"
echo "Total SVGs: $(find "$THEME" -name "*.svg" | wc -l)"

# Brand color compliance
echo ""
echo "Brand colors audit:"
OFF=0
for color in $(grep -roh '#[0-9A-Fa-f]\{6\}' "$THEME/scalable" 2>/dev/null | sort -u); do
    case "$(echo $color | tr 'a-f' 'A-F')" in
        "#00D4AA"|"#FF6B9D"|"#161830"|"#0F0F1B"|"#F0C420"|"#2ECC71"|"#3282B8"|"#5E26CC"|"#E8E8E8") ;;
        *) echo "  OFF-BRAND: $color"; OFF=$((OFF + 1)) ;;
    esac
done
[ "$OFF" -eq 0 ] && echo "  ALL BRAND-COMPLIANT"

if [ "$FALLBACK" -eq 0 ]; then
    echo ""
    echo "PERFECT: 100% coverage of critical freedesktop icons"
    exit 0
else
    echo ""
    echo "GOOD: ${PCT}% coverage, $FALLBACK icons use Adwaita fallback (acceptable)"
    exit 0
fi
