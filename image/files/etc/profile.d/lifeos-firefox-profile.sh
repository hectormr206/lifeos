# Ensure Firefox uses the LifeOS hardened profile.
# Firefox ignores /etc/skel profiles.ini on first run and creates a generic one.
# This script fixes it at every login to guarantee the hardened profile is active.

_lifeos_fix_firefox_profile() {
    local profiles_ini="$HOME/.mozilla/firefox/profiles.ini"
    local lifeos_profile_dir="$HOME/.mozilla/firefox/lifeos.default"

    # Only act if the LifeOS profile directory exists (copied from /etc/skel)
    [ -d "$lifeos_profile_dir" ] || return 0

    # Check if profiles.ini is missing or points to a non-LifeOS profile
    if [ ! -f "$profiles_ini" ] || ! grep -q 'Path=lifeos.default' "$profiles_ini" 2>/dev/null; then
        mkdir -p "$HOME/.mozilla/firefox"
        cat > "$profiles_ini" << 'FIREFOXEOF'
[Profile0]
Name=LifeOS
IsRelative=1
Path=lifeos.default
Default=1

[General]
StartWithLastProfile=1
Version=2
FIREFOXEOF
    fi

    # Remove any Install section that locks to a different profile
    if grep -q '^\[Install' "$profiles_ini" 2>/dev/null; then
        sed -i '/^\[Install/,/^$/d' "$profiles_ini"
    fi

    # Force ShowSelector=0 on the LifeOS profile. Firefox sometimes writes
    # ShowSelector=1 after using the "Manage Profiles" UI, which then pops a
    # profile chooser dialog on every launch — the tray would spawn one
    # chooser window per click and Hector sees "múltiples ventanas de error".
    if grep -q '^ShowSelector=1' "$profiles_ini" 2>/dev/null; then
        sed -i 's/^ShowSelector=1$/ShowSelector=0/' "$profiles_ini"
    fi

    # Sweep stale profile locks from unclean shutdowns. Only do this if no
    # firefox is currently running so we never steal a live lock.
    if ! pgrep -x firefox >/dev/null 2>&1; then
        find "$HOME/.mozilla/firefox" -maxdepth 2 \
            \( -name lock -o -name .parentlock \) \
            -mtime +0 -delete 2>/dev/null || true
    fi
}

_lifeos_fix_firefox_profile
unset -f _lifeos_fix_firefox_profile
