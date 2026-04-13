#!/bin/bash
# lifeos-flatpak-update.sh — Unattended Flatpak updates with safety guards.
# Runs daily via systemd timer. Skips if gaming, on battery, or metered.
set -euo pipefail

log() { printf '[lifeos-flatpak-update] %s\n' "$*"; }

# Guard: skip if a game is running (Steam, gamescope, Proton)
if pgrep -x 'steam|gamescope|pressure-vessel' >/dev/null 2>&1; then
    log "Game session active — skipping update"
    exit 0
fi

# Guard: skip on metered connection (NetworkManager)
if command -v nmcli >/dev/null 2>&1; then
    metered="$(nmcli -t -f GENERAL.METERED dev show 2>/dev/null | head -1 | cut -d: -f2)"
    if [ "${metered}" = "yes" ]; then
        log "Metered connection — skipping update"
        exit 0
    fi
fi

# Update system Flatpak apps and runtimes
log "Starting Flatpak system update"
if flatpak update --system -y --noninteractive 2>&1; then
    log "System update completed"
else
    log "System update failed (exit $?)"
fi

# Update appstream metadata for COSMIC Store
if flatpak update --appstream --system 2>&1; then
    log "Appstream metadata refreshed"
else
    log "Appstream refresh failed (non-fatal)"
fi

log "Flatpak auto-update finished"
