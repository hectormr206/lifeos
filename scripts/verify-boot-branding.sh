#!/bin/bash
# Verify LifeOS boot branding consistency (Plymouth + GRUB + Greeter + Desktop)
# Run this on the HOST system (not in Flatpak) to check actual installed files.
# Usage: sudo bash scripts/verify-boot-branding.sh
set -euo pipefail

PASS=0
FAIL=0
WARN=0

check() {
    local desc="$1" path="$2"
    if [ -f "$path" ] || [ -d "$path" ]; then
        echo "  OK: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc ($path not found)"
        FAIL=$((FAIL + 1))
    fi
}

check_contains() {
    local desc="$1" path="$2" pattern="$3"
    if [ -f "$path" ] && grep -q "$pattern" "$path" 2>/dev/null; then
        echo "  OK: $desc"
        PASS=$((PASS + 1))
    elif [ -f "$path" ]; then
        echo "  WARN: $desc ($path exists but doesn't contain '$pattern')"
        WARN=$((WARN + 1))
    else
        echo "  FAIL: $desc ($path not found)"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== LifeOS Boot Branding Verification ==="
echo ""

echo "[1. GRUB Theme]"
check "GRUB theme directory" "/usr/share/lifeos/grub-theme"
check "GRUB theme.txt" "/usr/share/lifeos/grub-theme/theme.txt"
check "GRUB installer script" "/usr/local/bin/lifeos-grub-theme.sh"
check_contains "GRUB uses LifeOS colors" "/usr/share/lifeos/grub-theme/theme.txt" "00D4AA"

echo ""
echo "[2. Plymouth Splash]"
check "Plymouth theme directory" "/usr/share/plymouth/themes/lifeos"
check "Plymouth config" "/usr/share/plymouth/themes/lifeos/lifeos.plymouth"
check "Plymouth script" "/usr/share/plymouth/themes/lifeos/lifeos.script"
check_contains "Plymouth references LifeOS" "/usr/share/plymouth/themes/lifeos/lifeos.plymouth" "LifeOS"
# Check if Plymouth is the active theme
if command -v plymouth-set-default-theme &>/dev/null; then
    ACTIVE=$(plymouth-set-default-theme 2>/dev/null || echo "unknown")
    if [ "$ACTIVE" = "lifeos" ]; then
        echo "  OK: Plymouth active theme is 'lifeos'"
        PASS=$((PASS + 1))
    else
        echo "  WARN: Plymouth active theme is '$ACTIVE' (expected 'lifeos')"
        WARN=$((WARN + 1))
    fi
fi

echo ""
echo "[3. Login Screen (cosmic-greeter)]"
check "Greeter wallpaper config" "/var/lib/cosmic-greeter/.config/cosmic/com.system76.CosmicBackground/v1/all"
check_contains "Greeter uses lifeos-lock.svg" "/var/lib/cosmic-greeter/.config/cosmic/com.system76.CosmicBackground/v1/all" "lifeos-lock.svg"
check "Greeter dark mode" "/var/lib/cosmic-greeter/.config/cosmic/com.system76.CosmicTheme.Mode/v1/is_dark"
check "Greeter accent color" "/var/lib/cosmic-greeter/.config/cosmic/com.system76.CosmicTheme.Dark.Builder/v1/accent"
check_contains "Greeter uses teal accent" "/var/lib/cosmic-greeter/.config/cosmic/com.system76.CosmicTheme.Dark.Builder/v1/accent" "0.831"

echo ""
echo "[4. Desktop (COSMIC)]"
check "Desktop wallpaper" "/usr/share/backgrounds/lifeos/lifeos-default.svg"
check "Lock screen wallpaper" "/usr/share/backgrounds/lifeos/lifeos-lock.svg"
check "Theme apply script" "/usr/local/bin/lifeos-apply-theme.sh"
check "Theme autostart desktop" "/etc/xdg/autostart/lifeos-theme.desktop"
check "Dark theme RON" "/usr/share/lifeos/themes/lifeos-dark.ron"
check_contains "Theme uses teal accent" "/usr/share/lifeos/themes/lifeos-dark.ron" "00D4AA"

echo ""
echo "[5. Icon Theme]"
check "Icon theme directory" "/usr/share/icons/LifeOS"
check "Icon index.theme" "/usr/share/icons/LifeOS/index.theme"
check_contains "Icon theme inherits Adwaita" "/usr/share/icons/LifeOS/index.theme" "Inherits=Adwaita"
ICON_COUNT=$(find /usr/share/icons/LifeOS -name "*.svg" 2>/dev/null | wc -l)
echo "  INFO: $ICON_COUNT SVG icons installed"

echo ""
echo "[6. Fonts]"
if command -v fc-list &>/dev/null; then
    if fc-list | grep -qi "inter"; then
        echo "  OK: Inter font installed"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: Inter font not found"
        FAIL=$((FAIL + 1))
    fi
    if fc-list | grep -qi "jetbrains"; then
        echo "  OK: JetBrains Mono font installed"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: JetBrains Mono font not found"
        FAIL=$((FAIL + 1))
    fi
else
    echo "  WARN: fc-list not available, can't verify fonts"
    WARN=$((WARN + 1))
fi

echo ""
echo "[7. Skeleton (new user defaults)]"
check "Skeleton wallpaper" "/etc/skel/.config/cosmic/com.system76.CosmicBackground/v1/all"
check "Skeleton icon theme" "/etc/skel/.config/cosmic/com.system76.CosmicTk/v1/icon_theme"
check "Skeleton font family" "/etc/skel/.config/cosmic/com.system76.CosmicTk/v1/font_family"
check "Skeleton monospace" "/etc/skel/.config/cosmic/com.system76.CosmicTk/v1/monospace_family"
check "Skeleton dark mode" "/etc/skel/.config/cosmic/com.system76.CosmicTheme.Mode/v1/is_dark"

echo ""
echo "=== RESULTS ==="
echo "Passed: $PASS"
echo "Warnings: $WARN"
echo "Failed: $FAIL"

if [ "$FAIL" -eq 0 ]; then
    echo ""
    echo "BOOT BRANDING: CONSISTENT"
else
    echo ""
    echo "BOOT BRANDING: $FAIL issues found"
    echo "Run on the LifeOS host (not in Flatpak) for accurate results."
fi
