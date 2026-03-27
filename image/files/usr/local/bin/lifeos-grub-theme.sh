#!/bin/bash
# LifeOS GRUB Theme Installer
# Safely installs the LifeOS branded GRUB theme to /boot/grub2/themes/
# Called from lifeos-first-boot.sh or manually via: sudo lifeos-grub-theme.sh
#
# Safety: only touches /boot/grub2/themes/ and /boot/grub2/user.cfg
# Does NOT modify grub.cfg or run grub2-mkconfig (unsafe on bootc)

set -euo pipefail

THEME_SRC="/usr/share/lifeos/grub-theme"
THEME_DST="/boot/grub2/themes/lifeos"
USER_CFG="/boot/grub2/user.cfg"
MARKER="/var/lib/lifeos/.grub-theme-installed"

# Skip if already installed (idempotent)
if [ -f "$MARKER" ] && [ -d "$THEME_DST" ]; then
    echo "[grub-theme] Already installed, skipping"
    exit 0
fi

# Verify source exists
if [ ! -d "$THEME_SRC" ]; then
    echo "[grub-theme] Source not found: $THEME_SRC"
    exit 1
fi

echo "[grub-theme] Installing LifeOS GRUB theme..."

# Copy theme files
mkdir -p "$THEME_DST"
cp -f "$THEME_SRC/background.png" "$THEME_DST/"
cp -f "$THEME_SRC/theme.txt" "$THEME_DST/"

# Generate PFF2 font from Inter (if grub2-mkfont is available)
if command -v grub2-mkfont >/dev/null 2>&1; then
    INTER_TTF=$(find /usr/share/fonts/ -name "Inter-Regular.otf" -o -name "Inter-Regular.ttf" -o -name "InterVariable.ttf" 2>/dev/null | head -1)
    if [ -n "$INTER_TTF" ]; then
        grub2-mkfont -s 18 -o "$THEME_DST/inter-18.pf2" "$INTER_TTF" 2>/dev/null || true
        grub2-mkfont -s 24 -o "$THEME_DST/inter-24.pf2" "$INTER_TTF" 2>/dev/null || true
        grub2-mkfont -s 14 -o "$THEME_DST/inter-14.pf2" "$INTER_TTF" 2>/dev/null || true
        grub2-mkfont -s 12 -o "$THEME_DST/inter-12.pf2" "$INTER_TTF" 2>/dev/null || true
        echo "[grub-theme] Fonts generated"
    else
        echo "[grub-theme] Inter font not found, using GRUB default font"
    fi
fi

# Configure GRUB to use the theme via user.cfg
# This is the SAFE way on Fedora Atomic — no grub2-mkconfig needed
# We append our settings to user.cfg (or create it)
if [ -f "$USER_CFG" ]; then
    # Remove any existing theme lines to avoid duplicates
    grep -v "GRUB_THEME\|GRUB_TERMINAL_OUTPUT\|GRUB_GFXMODE\|GRUB_TIMEOUT_STYLE" "$USER_CFG" > "${USER_CFG}.tmp" || true
    mv "${USER_CFG}.tmp" "$USER_CFG"
fi

# Append theme configuration
cat >> "$USER_CFG" << 'GRUBCFG'
GRUB_THEME="/boot/grub2/themes/lifeos/theme.txt"
GRUB_TERMINAL_OUTPUT="gfxterm"
GRUB_GFXMODE="auto"
GRUB_TIMEOUT_STYLE="menu"
GRUBCFG

echo "[grub-theme] user.cfg updated"

# Mark as installed
mkdir -p /var/lib/lifeos
touch "$MARKER"

echo "[grub-theme] LifeOS GRUB theme installed successfully"
echo "[grub-theme] Will be visible on next reboot"
