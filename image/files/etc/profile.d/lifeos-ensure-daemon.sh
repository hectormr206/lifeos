# LifeOS — Ensure lifeosd user service is active on every login.
# Prevents masked/disabled state from persisting across bootc updates.
# Runs silently in background to avoid slowing down shell startup.

(
    # Only for the main LifeOS user (UID 1000)
    [ "$(id -u)" = "1000" ] || exit 0

    # Remove any stale mask file that blocks the service
    rm -f "$HOME/.config/systemd/user/lifeosd.service" 2>/dev/null

    # Ensure the service is enabled and running
    systemctl --user unmask lifeosd.service 2>/dev/null
    systemctl --user enable lifeosd.service 2>/dev/null
    if ! systemctl --user is-active lifeosd.service >/dev/null 2>&1; then
        systemctl --user start lifeosd.service 2>/dev/null
    fi
) &>/dev/null &
