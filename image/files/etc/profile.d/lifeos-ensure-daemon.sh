# LifeOS — Ensure the canonical lifeosd user service is active on every login.
# Prevents masked/disabled state from persisting across bootc updates.
# Runs silently without leaving a shell job around.

# Only for the main LifeOS user (UID 1000)
[ "$(id -u)" = "1000" ] || return 0

# Re-entry guard: this script spawns a shell via systemd-run; without this
# guard, if that shell ever sources /etc/profile (e.g. via `sh -lc`), we
# would recurse infinitely and flood the user bus with systemd-run units.
[ -n "${LIFEOS_ENSURE_DAEMON_RAN:-}" ] && return 0
export LIFEOS_ENSURE_DAEMON_RAN=1

# Scrub stale user-scoped dropins that pin ExecStart to a non-canonical path
# (e.g. a developer target/debug binary left over from local builds). This
# trap persists across bootc updates because it lives in $HOME, silently
# masking the shipped /usr/bin/lifeosd. See
# docs/architecture/service-runtime.md and memory note
# project_lifeosd_stale_binary_override.md.
_lifeos_dropin_dir="$HOME/.config/systemd/user/lifeosd.service.d"
if [ -d "$_lifeos_dropin_dir" ]; then
    _lifeos_scrubbed=0
    for _f in "$_lifeos_dropin_dir"/*.conf "$_lifeos_dropin_dir"/*.conf.bak; do
        [ -f "$_f" ] || continue
        # Match any ExecStart= that points outside /usr/bin/lifeosd (the
        # canonical bootc binary). grep -E is POSIX-portable.
        if grep -Eq '^ExecStart=.*(target/debug|target/release|/home/|/var/home/)' "$_f" 2>/dev/null; then
            rm -f "$_f" 2>/dev/null && _lifeos_scrubbed=1
        fi
    done
    rmdir "$_lifeos_dropin_dir" 2>/dev/null || true
    if [ "$_lifeos_scrubbed" = "1" ]; then
        systemctl --user daemon-reload 2>/dev/null
        systemctl --user restart lifeosd.service 2>/dev/null || true
    fi
    unset _lifeos_scrubbed _f
fi
unset _lifeos_dropin_dir

# Only run once per user session: if lifeosd is already active, skip entirely.
# This also guarantees idempotency across the many shells a desktop session spawns.
if systemctl --user is-active lifeosd.service >/dev/null 2>&1; then
    return 0
fi

if command -v systemd-run >/dev/null 2>&1; then
    # NOTE: use `sh -c` (NOT `sh -lc`) so the spawned shell does NOT re-source
    # /etc/profile and re-enter this script. Pass the guard env var through.
    systemd-run --user --quiet --collect \
        --setenv=LIFEOS_ENSURE_DAEMON_RAN=1 \
        /bin/sh -c '
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
