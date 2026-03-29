#!/bin/bash
# Check brand compliance across all visual assets
set -euo pipefail
ICON_DIR="image/files/usr/share/icons/LifeOS/scalable"
APPROVED="#00D4AA #FF6B9D #161830 #0F0F1B #F0C420 #2ECC71 #3282B8 #5E26CC #E8E8E8"
ERRORS=0

for color in $(grep -roh '#[0-9A-Fa-f]\{6\}' "$ICON_DIR" 2>/dev/null | sort -u); do
    UPPER=$(echo "$color" | tr 'a-f' 'A-F')
    FOUND=false
    for approved in $APPROVED; do
        [ "$UPPER" = "$approved" ] && FOUND=true && break
    done
    if [ "$FOUND" = "false" ]; then
        echo "OFF-BRAND: $color"
        ERRORS=$((ERRORS + 1))
    fi
done

[ "$ERRORS" -eq 0 ] && echo "OK: All icons brand-compliant" || echo "FAIL: $ERRORS off-brand colors"
exit $ERRORS
