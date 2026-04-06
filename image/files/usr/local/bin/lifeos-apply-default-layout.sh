#!/bin/bash
# LifeOS — Apply default COSMIC desktop layout to existing user homes.
#
# Idempotent and non-destructive: this script copies COSMIC config files
# (background, panel entries, panel + dock per-entry settings) from the
# system skel into each real user's $HOME/.config/cosmic, BUT only when
# the destination file does not already exist. That way we never
# overwrite a user's customisation.
#
# A per-user marker file is also written; if the marker exists for a
# user, we skip them entirely on subsequent runs.
#
# This script is intended to be invoked from lifeos-first-boot.sh.
# It must NEVER fail the calling script — every risky operation is
# wrapped, and we always exit 0.

set -u
# Intentionally NOT using `set -e` — we never want to fail.

LOG_TAG="[LifeOS]"
SKEL_COSMIC="/etc/skel/.config/cosmic"
LAYOUT_VERSION="v2"
WALLPAPER_STATE_SYNC="/usr/local/bin/lifeos-sync-cosmic-wallpaper-state.sh"
DEFAULT_WALLPAPER="/usr/share/backgrounds/lifeos/lifeos-default.png"

log()      { echo "${LOG_TAG} $*"; }
log_warn() { echo "${LOG_TAG} [!] $*"; }

# COSMIC config groups we manage. Anything else the user has stays untouched.
COSMIC_GROUPS=(
    "com.system76.CosmicBackground/v1"
    "com.system76.CosmicPanel/v1"
    "com.system76.CosmicPanel.Panel/v1"
    "com.system76.CosmicPanel.Dock/v1"
    "com.system76.CosmicComp/v1"
    "com.system76.CosmicTheme.Dark.Builder/v1"
    "com.system76.CosmicTheme.Light.Builder/v1"
    "com.system76.CosmicTheme.Mode/v1"
    "com.system76.CosmicTk/v1"
    "com.system76.CosmicSettings.FontConfig/v1"
)

# Copy a single file from skel to user dir if and only if the destination
# does not already exist. Respects existing user customisations.
copy_if_absent() {
    local src="$1"
    local dst="$2"
    if [ -e "$dst" ]; then
        return 0
    fi
    mkdir -p "$(dirname "$dst")" 2>/dev/null || return 0
    cp -p "$src" "$dst" 2>/dev/null || return 0
}

apply_for_user() {
    local user_name="$1"
    local user_home="$2"
    local user_uid="$3"
    local user_gid="$4"

    local cosmic_dir="${user_home}/.config/cosmic"
    local marker_dir="${user_home}/.local/share/lifeos"
    local marker="${marker_dir}/.layout-applied-${LAYOUT_VERSION}"

    if [ -e "$marker" ]; then
        log "Layout ya aplicado para ${user_name}, omitiendo"
        return 0
    fi

    log "Aplicando layout COSMIC por defecto para ${user_name}..."

    local group src_group dst_group f rel
    for group in "${COSMIC_GROUPS[@]}"; do
        src_group="${SKEL_COSMIC}/${group}"
        dst_group="${cosmic_dir}/${group}"
        if [ ! -d "$src_group" ]; then
            continue
        fi
        # Iterate every regular file in the source group (one level deep is fine —
        # COSMIC stores one file per field).
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            rel="${f#${src_group}/}"
            copy_if_absent "$f" "${dst_group}/${rel}"
        done < <(find "$src_group" -type f 2>/dev/null)
    done

    # chown what we just touched (best-effort).
    if [ -d "$cosmic_dir" ]; then
        chown -R "${user_uid}:${user_gid}" "$cosmic_dir" 2>/dev/null || \
            log_warn "No se pudo cambiar dueño de ${cosmic_dir}"
    fi

    if [ -x "$WALLPAPER_STATE_SYNC" ] && [ -f "$DEFAULT_WALLPAPER" ]; then
        "$WALLPAPER_STATE_SYNC" "$user_home" "$DEFAULT_WALLPAPER" "${user_uid}:${user_gid}" || \
            log_warn "No se pudo sincronizar el state de wallpaper para ${user_name}"
    fi

    # Write idempotency marker.
    mkdir -p "$marker_dir" 2>/dev/null || true
    chown -R "${user_uid}:${user_gid}" "$marker_dir" 2>/dev/null || true
    : > "$marker" 2>/dev/null || true
    chown "${user_uid}:${user_gid}" "$marker" 2>/dev/null || true

    log "Layout aplicado para ${user_name}"
}

main() {
    if [ ! -d "$SKEL_COSMIC" ]; then
        log_warn "No existe ${SKEL_COSMIC}, nada que aplicar"
        return 0
    fi

    local home_entry user_name passwd_line user_uid user_gid user_shell
    for home_entry in /home/*; do
        [ -d "$home_entry" ] || continue
        user_name="$(basename "$home_entry")"

        passwd_line="$(getent passwd "$user_name" 2>/dev/null || true)"
        if [ -z "$passwd_line" ]; then
            continue
        fi

        user_uid="$(echo "$passwd_line" | cut -d: -f3)"
        user_gid="$(echo "$passwd_line" | cut -d: -f4)"
        user_shell="$(echo "$passwd_line" | cut -d: -f7)"

        # Only real, login-capable users.
        if [ -z "$user_uid" ] || [ "$user_uid" -lt 1000 ]; then
            continue
        fi
        case "$user_shell" in
            */nologin|*/false|"")
                continue
                ;;
        esac

        apply_for_user "$user_name" "$home_entry" "$user_uid" "$user_gid" || \
            log_warn "Fallo no fatal aplicando layout a ${user_name}"
    done
}

main "$@" || true
exit 0
