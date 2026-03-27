#!/bin/sh
# LifeOS Theme Applier — applies the complete LifeOS visual identity.
# Called via XDG autostart on login. Only runs once per version (marker file).
# Also runs on update to refresh the theme.
set -eu

THEME_DIR="/usr/share/lifeos/themes"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/lifeos"
MARKER="$STATE_DIR/theme-applied-version"
CURRENT_VERSION="0.2.0"

mkdir -p "$STATE_DIR"

# Skip if already applied for this version
if [ -f "$MARKER" ] && [ "$(cat "$MARKER")" = "$CURRENT_VERSION" ]; then
    exit 0
fi

# Wait for COSMIC compositor to be ready
sleep 3

echo "[lifeos-theme] Applying LifeOS visual identity v${CURRENT_VERSION}..."

# ── 1. Import LifeOS dark theme (accent, colors, frosted glass, corners) ──
if [ -f "$THEME_DIR/lifeos-dark.ron" ]; then
    cosmic-settings appearance import "$THEME_DIR/lifeos-dark.ron" 2>/dev/null && \
        echo "[lifeos-theme] Dark theme applied" || \
        echo "[lifeos-theme] Theme import failed (non-fatal)"
fi

# ── 2. Panel: floating, semi-transparent, rounded ──
PANEL="$HOME/.config/cosmic/com.system76.CosmicPanel.Panel/v1"
mkdir -p "$PANEL"
echo "0.85" > "$PANEL/opacity"
echo "false" > "$PANEL/expand_to_edges"
echo "12" > "$PANEL/border_radius"
echo "4" > "$PANEL/spacing"
echo "true" > "$PANEL/anchor_gap"
echo "4" > "$PANEL/margin"

# ── 3. Dock: floating, transparent, rounded, auto-hide ──
DOCK="$HOME/.config/cosmic/com.system76.CosmicPanel.Dock/v1"
mkdir -p "$DOCK"
echo "0.75" > "$DOCK/opacity"
echo "L" > "$DOCK/size"
echo "false" > "$DOCK/expand_to_edges"
echo "160" > "$DOCK/border_radius"
echo "true" > "$DOCK/anchor_gap"
echo "4" > "$DOCK/margin"
cat > "$DOCK/autohide" << 'AUTOHIDE'
Some((
    wait_time: 1000,
    transition_time: 200,
    handle_size: 4,
    unhide_delay: 200,
))
AUTOHIDE

# ── 4. Compositor: active hint enabled ──
COMP="$HOME/.config/cosmic/com.system76.CosmicComp/v1"
mkdir -p "$COMP"
echo "true" > "$COMP/active_hint"

# ── 5. Wallpaper (prefer PNG over SVG) ──
WALLPAPER="/usr/share/backgrounds/lifeos/lifeos-axi-night.png"
[ ! -f "$WALLPAPER" ] && WALLPAPER="/usr/share/backgrounds/lifeos/lifeos-axi-night.svg"
if [ -f "$WALLPAPER" ]; then
    BG_DIR="$HOME/.config/cosmic/com.system76.CosmicBackground/v1"
    mkdir -p "$BG_DIR"
    printf '[("%s", "zoom")]\n' "$WALLPAPER" > "$BG_DIR/all"
fi

# ── 6. Dark mode ──
MODE_DIR="$HOME/.config/cosmic/com.system76.CosmicTheme.Mode/v1"
mkdir -p "$MODE_DIR"
echo "true" > "$MODE_DIR/is_dark"

# ── 7. Icon theme: LifeOS ──
TK_DIR="$HOME/.config/cosmic/com.system76.CosmicTk/v1"
mkdir -p "$TK_DIR"
echo '"LifeOS"' > "$TK_DIR/icon_theme"

echo "[lifeos-theme] LifeOS identity applied successfully"

# Mark as applied
printf '%s' "$CURRENT_VERSION" > "$MARKER"
