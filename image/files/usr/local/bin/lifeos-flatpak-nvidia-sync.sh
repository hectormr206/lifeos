#!/bin/bash
# lifeos-flatpak-nvidia-sync.sh — Sync Flatpak GL extensions with host Nvidia driver.
# Runs on boot and after bootc upgrades. Ensures GPU-accelerated Flatpak apps
# (Steam, Blender, browsers) always match the host driver version.
set -euo pipefail

log() { printf '[lifeos-nvidia-sync] %s\n' "$*"; }

# Skip on non-Nvidia systems
if ! command -v nvidia-smi >/dev/null 2>&1; then
    log "No nvidia-smi found — not an Nvidia system, skipping"
    exit 0
fi

# Get host driver version
DRIVER_VERSION="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 | tr -d '[:space:]')"
if [ -z "${DRIVER_VERSION}" ]; then
    log "Could not detect Nvidia driver version — skipping"
    exit 0
fi

# Convert 580.126.18 → nvidia-580-126-18
GL_SUFFIX="nvidia-${DRIVER_VERSION//./-}"
log "Host driver: ${DRIVER_VERSION} → extension: ${GL_SUFFIX}"

# Extensions to sync
EXTENSIONS=(
    "org.freedesktop.Platform.GL.${GL_SUFFIX}"
    "org.freedesktop.Platform.GL32.${GL_SUFFIX}"
)

INSTALLED=0
ALREADY=0

for ext in "${EXTENSIONS[@]}"; do
    if flatpak info --system "${ext}" >/dev/null 2>&1; then
        log "${ext} — already installed"
        ((ALREADY++)) || true
    else
        log "Installing ${ext}"
        if flatpak install --system -y --noninteractive flathub "${ext}" 2>&1; then
            log "${ext} — installed successfully"
            ((INSTALLED++)) || true
        else
            log "${ext} — install failed (may not be available yet for ${DRIVER_VERSION})"
        fi
    fi
done

# Also ensure VAAPI runtime is present
VAAPI_EXT="org.freedesktop.Platform.VAAPI.nvidia"
if ! flatpak info --system "${VAAPI_EXT}" >/dev/null 2>&1; then
    log "Installing ${VAAPI_EXT}"
    flatpak install --system -y --noninteractive flathub "${VAAPI_EXT}" 2>&1 || true
fi

# Clean up old GL extensions that don't match current driver
log "Checking for stale GL extensions"
flatpak list --system --runtime --columns=application 2>/dev/null \
    | rg '^org\.freedesktop\.Platform\.GL(32)?\.nvidia-' \
    | while read -r old_ext; do
        if [[ "${old_ext}" != *"${GL_SUFFIX}" ]]; then
            log "Removing stale extension: ${old_ext}"
            flatpak uninstall --system -y --noninteractive "${old_ext}" 2>&1 || true
        fi
    done

log "Sync complete: ${INSTALLED} installed, ${ALREADY} already present"
