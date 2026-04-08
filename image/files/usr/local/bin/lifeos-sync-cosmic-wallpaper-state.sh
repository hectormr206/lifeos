#!/bin/sh
# Sync cosmic-bg state for a home directory using the currently connected outputs.
set -eu

HOME_DIR="${1:-}"
WALLPAPER="${2:-}"
OWNER_SPEC="${3:-}"
STATE_DIR="$HOME_DIR/.local/state/cosmic/com.system76.CosmicBackground/v1"

if [ -z "$HOME_DIR" ] || [ -z "$WALLPAPER" ]; then
    echo "usage: $0 HOME_DIR WALLPAPER_PATH [UID:GID]" >&2
    exit 1
fi

mkdir -p "$STATE_DIR"

TMP_FILE="$(mktemp)"
{
    echo '['
    CONNECTED_OUTPUTS=$(
        find /sys/class/drm -mindepth 1 -maxdepth 1 -type d 2>/dev/null | \
        while IFS= read -r entry; do
            status_file="$entry/status"
            [ -f "$status_file" ] || continue
            [ "$(cat "$status_file" 2>/dev/null)" = "connected" ] || continue
            basename "$entry" | sed -E 's/^card[0-9]+-//'
        done | sort -u
    )

    if [ -n "$CONNECTED_OUTPUTS" ]; then
        echo "$CONNECTED_OUTPUTS" | while IFS= read -r output_name; do
            [ -n "$output_name" ] || continue
            printf '    ("%s", Path("%s")),\n' "$output_name" "$WALLPAPER"
        done
    else
        printf '    ("all", Path("%s")),\n' "$WALLPAPER"
    fi

    echo ']'
} > "$TMP_FILE"

install -Dm0644 "$TMP_FILE" "$STATE_DIR/wallpapers"
rm -f "$TMP_FILE"

if [ -n "$OWNER_SPEC" ]; then
    chown -R "$OWNER_SPEC" "$HOME_DIR/.local/state/cosmic" 2>/dev/null || true
fi
