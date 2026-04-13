#!/bin/sh
# LifeOS Theme Applier — applies the complete LifeOS visual identity.
# Called via XDG autostart on login. Only runs once per version (marker file).
# Also runs on update to refresh the theme.
# Usage: lifeos-apply-theme.sh [--force]
#   --force   Re-apply theme even if already applied for this version
set -eu

THEME_DIR="/usr/share/lifeos/themes"
VERSION_METADATA_ENV="/usr/share/lifeos/version-metadata.env"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/lifeos"
MARKER="$STATE_DIR/theme-applied-version"
FORCE=false
WALLPAPER_STATE_SYNC="/usr/local/bin/lifeos-sync-cosmic-wallpaper-state.sh"

# Theme rollout markers follow the formal package release metadata, not the
# booted bootc/channel version, so edge builds do not force re-application.
if [ -f "$VERSION_METADATA_ENV" ]; then
    # shellcheck disable=SC1090,SC1091
    . "$VERSION_METADATA_ENV"
fi

CURRENT_VERSION="${LIFEOS_PACKAGE_VERSION:-unknown}"
THEME_MARKER_EPOCH="${LIFEOS_THEME_MARKER_EPOCH:-cosmic-v2}"
MARKER_VERSION="${CURRENT_VERSION}-${THEME_MARKER_EPOCH}"

for arg in "$@"; do
    case "$arg" in
        --force) FORCE=true ;;
    esac
done

mkdir -p "$STATE_DIR"

write_background_entry() {
    target_dir="$1"
    wallpaper="$2"

    mkdir -p "$target_dir"

    cat > "$target_dir/all" << EOF
(
    output: "all",
    source: Path("$wallpaper"),
    filter_by_theme: false,
    rotation_frequency: 300,
    filter_method: Lanczos,
    scaling_mode: Zoom,
    sampling_method: Alphanumeric,
)
EOF

    printf 'true\n' > "$target_dir/same-on-all"
}

write_font_object() {
    target="$1"
    family="$2"

    cat > "$target" << EOF
(
    family: "$family",
    weight: Normal,
    stretch: Normal,
    style: Normal,
)
EOF
}

# Skip if already applied for this version (unless --force)
if [ "$FORCE" = "false" ] && [ -f "$MARKER" ] && [ "$(cat "$MARKER")" = "$MARKER_VERSION" ]; then
    exit 0
fi

# Wait for COSMIC compositor to be ready (retry up to 15 seconds)
READY=false
attempts_left=15
while [ "$attempts_left" -gt 0 ]; do
    if command -v cosmic-settings >/dev/null 2>&1; then
        READY=true
        break
    fi
    sleep 1
    attempts_left=$((attempts_left - 1))
done

if [ "$READY" = "false" ]; then
    echo "[lifeos-theme] WARN: cosmic-settings not found after 15s, applying anyway"
fi

echo "[lifeos-theme] Applying LifeOS visual identity v${CURRENT_VERSION}..."

# ── 1. Import LifeOS dark theme (accent, colors, frosted glass, corners) ──
if [ -f "$THEME_DIR/lifeos-dark.ron" ]; then
    cosmic-settings appearance import "$THEME_DIR/lifeos-dark.ron" 2>/dev/null && \
        echo "[lifeos-theme] Dark theme applied" || \
        echo "[lifeos-theme] Theme import failed (non-fatal)"
fi

# ── 2. Panel: floating, semi-transparent, rounded ──
PANEL_CONTAINER="$HOME/.config/cosmic/com.system76.CosmicPanel/v1"
mkdir -p "$PANEL_CONTAINER"
cat > "$PANEL_CONTAINER/entries" << 'PANEL_ENTRIES'
[
    "Panel",
    "Dock",
]
PANEL_ENTRIES

PANEL="$HOME/.config/cosmic/com.system76.CosmicPanel.Panel/v1"
mkdir -p "$PANEL"
echo 'ThemeDefault' > "$PANEL/background"
echo 'OnDemand' > "$PANEL/keyboard_interactivity"
echo 'Some(500)' > "$PANEL/autohover_delay_ms"
echo 'true' > "$PANEL/exclusive_zone"
echo "0.85" > "$PANEL/opacity"
echo "false" > "$PANEL/expand_to_edges"
echo "12" > "$PANEL/border_radius"
echo "0" > "$PANEL/padding"
echo "0.5" > "$PANEL/padding_overlap"
echo "None" > "$PANEL/size_center"
echo "None" > "$PANEL/size_wings"
echo "4" > "$PANEL/spacing"
echo "true" > "$PANEL/anchor_gap"
echo "4" > "$PANEL/margin"
cat > "$PANEL/plugins_center" << 'PANEL_CENTER'
Some([
    "com.system76.CosmicAppletTime",
])
PANEL_CENTER
cat > "$PANEL/plugins_wings" << 'PANEL_WINGS'
Some(([
    "com.system76.CosmicAppletWorkspaces",
    "com.system76.CosmicPanelAppButton",
], [
    "com.system76.CosmicAppletInputSources",
    "com.system76.CosmicAppletA11y",
    "com.system76.CosmicAppletStatusArea",
    "com.system76.CosmicAppletTiling",
    "com.system76.CosmicAppletAudio",
    "com.system76.CosmicAppletBluetooth",
    "com.system76.CosmicAppletNetwork",
    "com.system76.CosmicAppletBattery",
    "com.system76.CosmicAppletNotifications",
    "com.system76.CosmicAppletPower",
]))
PANEL_WINGS

# ── 3. Dock: floating, transparent, rounded, auto-hide ──
DOCK="$HOME/.config/cosmic/com.system76.CosmicPanel.Dock/v1"
mkdir -p "$DOCK"
echo 'ThemeDefault' > "$DOCK/background"
echo 'OnDemand' > "$DOCK/keyboard_interactivity"
echo 'Some(500)' > "$DOCK/autohover_delay_ms"
echo 'false' > "$DOCK/exclusive_zone"
echo "0.75" > "$DOCK/opacity"
echo "L" > "$DOCK/size"
echo "false" > "$DOCK/expand_to_edges"
echo "160" > "$DOCK/border_radius"
echo "0.5" > "$DOCK/padding_overlap"
echo "None" > "$DOCK/size_center"
echo "None" > "$DOCK/size_wings"
echo "true" > "$DOCK/anchor_gap"
echo "4" > "$DOCK/margin"
echo "0" > "$DOCK/spacing"
cat > "$DOCK/autohide" << 'AUTOHIDE'
Some((
    wait_time: 1000,
    transition_time: 200,
    handle_size: 4,
    unhide_delay: 200,
))
AUTOHIDE
cat > "$DOCK/plugins_center" << 'DOCK_CENTER'
Some([
    "com.system76.CosmicPanelLauncherButton",
    "com.system76.CosmicPanelWorkspacesButton",
    "com.system76.CosmicPanelAppButton",
    "com.system76.CosmicAppList",
    "com.system76.CosmicAppletMinimize",
])
DOCK_CENTER
printf 'None\n' > "$DOCK/plugins_wings"

# ── 4. Compositor: active hint enabled ──
COMP="$HOME/.config/cosmic/com.system76.CosmicComp/v1"
mkdir -p "$COMP"
echo "true" > "$COMP/active_hint"

# ── 5. Wallpaper (COSMIC currently expects raster assets via cosmic-bg) ──
WALLPAPER="/usr/share/backgrounds/lifeos/lifeos-default.png"
[ ! -f "$WALLPAPER" ] && WALLPAPER="/usr/share/backgrounds/lifeos/lifeos-axi-night.png"
if [ -f "$WALLPAPER" ]; then
    BG_DIR="$HOME/.config/cosmic/com.system76.CosmicBackground/v1"
    write_background_entry "$BG_DIR" "$WALLPAPER"

    if [ -x "$WALLPAPER_STATE_SYNC" ]; then
        "$WALLPAPER_STATE_SYNC" "$HOME" "$WALLPAPER" || \
            echo "[lifeos-theme] Wallpaper state sync failed (non-fatal)"
    fi
fi

# ── 6. Fonts: Inter (UI) + JetBrains Mono (terminal/code) ──
TK_DIR="$HOME/.config/cosmic/com.system76.CosmicTk/v1"
FONTCFG_DIR="$HOME/.config/cosmic/com.system76.CosmicSettings.FontConfig/v1"
mkdir -p "$TK_DIR" "$FONTCFG_DIR" "$COMP"
printf '"Inter"\n' > "$TK_DIR/font_family"
printf '"JetBrains Mono"\n' > "$TK_DIR/monospace_family"
write_font_object "$TK_DIR/interface_font" "Inter"
write_font_object "$TK_DIR/monospace_font" "JetBrains Mono"
printf '"Inter"\n' > "$FONTCFG_DIR/font_family"
printf '"JetBrains Mono"\n' > "$FONTCFG_DIR/monospace_family"
printf '"Inter"\n' > "$COMP/font_family"
printf '"JetBrains Mono"\n' > "$COMP/monospace_family"
echo "[lifeos-theme] Fonts set: Inter + JetBrains Mono"

# ── 7. Dark mode ──
MODE_DIR="$HOME/.config/cosmic/com.system76.CosmicTheme.Mode/v1"
mkdir -p "$MODE_DIR"
echo "true" > "$MODE_DIR/is_dark"

# ── 8. Icon theme ──
echo '"LifeOS"' > "$TK_DIR/icon_theme"

echo "[lifeos-theme] LifeOS identity applied successfully (v${CURRENT_VERSION})"

# Mark as applied
printf '%s' "$MARKER_VERSION" > "$MARKER"
