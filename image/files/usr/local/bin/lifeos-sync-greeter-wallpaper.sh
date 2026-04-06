#!/bin/sh
# Keep cosmic-greeter wallpaper state aligned with the shipped LifeOS branding.
set -eu

WALLPAPER_STATE_SYNC="/usr/local/bin/lifeos-sync-cosmic-wallpaper-state.sh"
GREETER_HOME="/var/lib/cosmic-greeter"
GREETER_USER="cosmic-greeter"
WALLPAPER="/usr/share/backgrounds/lifeos/lifeos-lock.png"

if [ ! -x "$WALLPAPER_STATE_SYNC" ] || [ ! -f "$WALLPAPER" ]; then
    exit 0
fi

if greeter_entry="$(getent passwd "$GREETER_USER" 2>/dev/null)"; then
    GREETER_HOME="$(echo "$greeter_entry" | cut -d: -f6)"
    GREETER_UID="$(echo "$greeter_entry" | cut -d: -f3)"
    GREETER_GID="$(echo "$greeter_entry" | cut -d: -f4)"
    OWNER_SPEC="${GREETER_UID}:${GREETER_GID}"
    "$WALLPAPER_STATE_SYNC" "$GREETER_HOME" "$WALLPAPER" "$OWNER_SPEC"
else
    mkdir -p "$GREETER_HOME"
    "$WALLPAPER_STATE_SYNC" "$GREETER_HOME" "$WALLPAPER"
fi
