#!/bin/sh
# LifeOS Theme Applier — applies the complete LifeOS visual identity.
# Called via XDG autostart on login. Only runs once per version (marker file).
#
# CRITICAL DESIGN RULE: This script NEVER overwrites existing user
# customisations.  Every write uses write_if_absent() which skips the
# file if it already exists.  The only exception is the COSMIC theme
# import (cosmic-settings appearance import) which is additive and
# handled by the compositor itself.
#
# To forcibly reset everything to LifeOS defaults, run:
#   lifeos-apply-theme.sh --force
#
# Usage: lifeos-apply-theme.sh [--force]
#   --force   Re-apply theme even if user has customised files
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

# ── Helper: write a file ONLY if it does not already exist ──
# This is the key guarantee: user customisations are NEVER overwritten.
# --force bypasses this check (explicit user intent to reset).
write_if_absent() {
    target="$1"
    content="$2"
    if [ "$FORCE" = "false" ] && [ -e "$target" ]; then
        return 0
    fi
    mkdir -p "$(dirname "$target")" 2>/dev/null || return 0
    printf '%s\n' "$content" > "$target"
}

# Same as write_if_absent but takes content from stdin (for heredocs).
write_if_absent_stdin() {
    target="$1"
    if [ "$FORCE" = "false" ] && [ -e "$target" ]; then
        cat > /dev/null  # drain stdin
        return 0
    fi
    mkdir -p "$(dirname "$target")" 2>/dev/null || return 0
    cat > "$target"
}

write_background_entry() {
    target_dir="$1"
    wallpaper="$2"

    write_if_absent_stdin "$target_dir/all" << EOF
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

    write_if_absent "$target_dir/same-on-all" "true"
}

write_font_object() {
    target="$1"
    family="$2"

    write_if_absent_stdin "$target" << EOF
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

echo "[lifeos-theme] Applying LifeOS visual identity v${CURRENT_VERSION} (preserve user config)..."

# ── 1. Import LifeOS dark theme (accent, colors, frosted glass, corners) ──
# NOTE: cosmic-settings import is additive/compositor-managed, safe to run.
if [ -f "$THEME_DIR/lifeos-dark.ron" ]; then
    cosmic-settings appearance import "$THEME_DIR/lifeos-dark.ron" 2>/dev/null && \
        echo "[lifeos-theme] Dark theme applied" || \
        echo "[lifeos-theme] Theme import failed (non-fatal)"
fi

# ── 2. Panel: floating, semi-transparent, rounded ──
PANEL_CONTAINER="$HOME/.config/cosmic/com.system76.CosmicPanel/v1"
write_if_absent_stdin "$PANEL_CONTAINER/entries" << 'PANEL_ENTRIES'
[
    "Panel",
    "Dock",
]
PANEL_ENTRIES

PANEL="$HOME/.config/cosmic/com.system76.CosmicPanel.Panel/v1"
write_if_absent "$PANEL/background" "ThemeDefault"
write_if_absent "$PANEL/keyboard_interactivity" "OnDemand"
write_if_absent "$PANEL/autohover_delay_ms" "Some(500)"
write_if_absent "$PANEL/exclusive_zone" "true"
write_if_absent "$PANEL/opacity" "0.85"
write_if_absent "$PANEL/expand_to_edges" "false"
write_if_absent "$PANEL/border_radius" "12"
write_if_absent "$PANEL/padding" "0"
write_if_absent "$PANEL/padding_overlap" "0.5"
write_if_absent "$PANEL/size_center" "None"
write_if_absent "$PANEL/size_wings" "None"
write_if_absent "$PANEL/spacing" "4"
write_if_absent "$PANEL/anchor_gap" "true"
write_if_absent "$PANEL/margin" "4"
write_if_absent_stdin "$PANEL/plugins_center" << 'PANEL_CENTER'
Some([
    "com.system76.CosmicAppletTime",
])
PANEL_CENTER
write_if_absent_stdin "$PANEL/plugins_wings" << 'PANEL_WINGS'
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
write_if_absent "$DOCK/background" "ThemeDefault"
write_if_absent "$DOCK/keyboard_interactivity" "OnDemand"
write_if_absent "$DOCK/autohover_delay_ms" "Some(500)"
write_if_absent "$DOCK/exclusive_zone" "false"
write_if_absent "$DOCK/opacity" "0.75"
write_if_absent "$DOCK/size" "L"
write_if_absent "$DOCK/expand_to_edges" "false"
write_if_absent "$DOCK/border_radius" "160"
write_if_absent "$DOCK/padding_overlap" "0.5"
write_if_absent "$DOCK/size_center" "None"
write_if_absent "$DOCK/size_wings" "None"
write_if_absent "$DOCK/anchor_gap" "true"
write_if_absent "$DOCK/margin" "4"
write_if_absent "$DOCK/spacing" "0"
write_if_absent_stdin "$DOCK/autohide" << 'AUTOHIDE'
Some((
    wait_time: 1000,
    transition_time: 200,
    handle_size: 4,
    unhide_delay: 200,
))
AUTOHIDE
write_if_absent_stdin "$DOCK/plugins_center" << 'DOCK_CENTER'
Some([
    "com.system76.CosmicPanelLauncherButton",
    "com.system76.CosmicPanelWorkspacesButton",
    "com.system76.CosmicPanelAppButton",
    "com.system76.CosmicAppList",
    "com.system76.CosmicAppletMinimize",
])
DOCK_CENTER
write_if_absent "$DOCK/plugins_wings" "None"

# ── 4. Compositor: active hint enabled ──
COMP="$HOME/.config/cosmic/com.system76.CosmicComp/v1"
write_if_absent "$COMP/active_hint" "true"

# ── 5. Wallpaper (COSMIC currently expects raster assets via cosmic-bg) ──
WALLPAPER="/usr/share/backgrounds/lifeos/lifeos-default.png"
[ ! -f "$WALLPAPER" ] && WALLPAPER="/usr/share/backgrounds/lifeos/lifeos-axi-night.png"
if [ -f "$WALLPAPER" ]; then
    BG_DIR="$HOME/.config/cosmic/com.system76.CosmicBackground/v1"
    # Check BEFORE write_background_entry so we know if we actually wrote
    BG_ALREADY_EXISTS=false
    [ -e "$BG_DIR/all" ] && BG_ALREADY_EXISTS=true

    write_background_entry "$BG_DIR" "$WALLPAPER"

    # Only sync wallpaper state if we actually wrote new config
    if [ -x "$WALLPAPER_STATE_SYNC" ]; then
        if [ "$FORCE" = "true" ] || [ "$BG_ALREADY_EXISTS" = "false" ]; then
            "$WALLPAPER_STATE_SYNC" "$HOME" "$WALLPAPER" || \
                echo "[lifeos-theme] Wallpaper state sync failed (non-fatal)"
        fi
    fi
fi

# ── 6. Fonts: Inter (UI) + JetBrains Mono (terminal/code) ──
TK_DIR="$HOME/.config/cosmic/com.system76.CosmicTk/v1"
FONTCFG_DIR="$HOME/.config/cosmic/com.system76.CosmicSettings.FontConfig/v1"
write_if_absent "$TK_DIR/font_family" '"Inter"'
write_if_absent "$TK_DIR/monospace_family" '"JetBrains Mono"'
write_font_object "$TK_DIR/interface_font" "Inter"
write_font_object "$TK_DIR/monospace_font" "JetBrains Mono"
write_if_absent "$FONTCFG_DIR/font_family" '"Inter"'
write_if_absent "$FONTCFG_DIR/monospace_family" '"JetBrains Mono"'
write_if_absent "$COMP/font_family" '"Inter"'
write_if_absent "$COMP/monospace_family" '"JetBrains Mono"'
echo "[lifeos-theme] Fonts set (preserved existing)"

# ── 7. Dark mode ──
MODE_DIR="$HOME/.config/cosmic/com.system76.CosmicTheme.Mode/v1"
write_if_absent "$MODE_DIR/is_dark" "true"

# ── 8. Icon theme ──
write_if_absent "$TK_DIR/icon_theme" '"LifeOS"'

echo "[lifeos-theme] LifeOS identity applied successfully (v${CURRENT_VERSION})"

# Mark as applied
printf '%s' "$MARKER_VERSION" > "$MARKER"
