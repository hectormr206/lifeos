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

# Seed AccountsService icon for the `lifeos` user so cosmic-greeter can render
# the avatar referenced by /var/lib/AccountsService/users/lifeos (Icon=…).
# Silent no-op if the source asset is missing or the icon already present.
ICON_SRC="/usr/share/icons/LifeOS/512x512/apps/lifeos-axi.png"
ICON_DEST="/var/lib/AccountsService/icons/lifeos"
if [ -f "$ICON_SRC" ] && [ ! -f "$ICON_DEST" ]; then
    mkdir -p /var/lib/AccountsService/icons
    install -m 0644 -o root -g root "$ICON_SRC" "$ICON_DEST"
fi
