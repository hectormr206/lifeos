# LifeOS — Ensure the canonical lifeosd user service is active on every login.
# Prevents masked/disabled state from persisting across bootc updates.
# Runs silently without leaving a shell job around.

# Only for the main LifeOS user (UID 1000)
[ "$(id -u)" = "1000" ] || return 0

if command -v systemd-run >/dev/null 2>&1; then
    systemd-run --user --quiet --collect /bin/sh -lc '
        rm -f "$HOME/.config/systemd/user/lifeosd.service" 2>/dev/null
        systemctl --user unmask lifeosd.service 2>/dev/null
        systemctl --user enable lifeosd.service 2>/dev/null
        if ! systemctl --user is-active lifeosd.service >/dev/null 2>&1; then
            systemctl --user start lifeosd.service 2>/dev/null
        fi
    ' >/dev/null 2>&1 || true
else
    (
        rm -f "$HOME/.config/systemd/user/lifeosd.service" 2>/dev/null
        systemctl --user unmask lifeosd.service 2>/dev/null
        systemctl --user enable lifeosd.service 2>/dev/null
        if ! systemctl --user is-active lifeosd.service >/dev/null 2>&1; then
            systemctl --user start lifeosd.service 2>/dev/null
        fi
    ) >/dev/null 2>&1 & disown 2>/dev/null || true
fi
