#!/bin/bash
# LifeOS SimpleX Chat setup — bootstrap the Axi bot profile on first run.
#
# simplex-chat creates its SQLite databases on first invocation but drops
# into an interactive "display name:" prompt that systemd can't satisfy
# (stdin is /dev/null under a unit without TTY). Without a pre-created
# profile the service would restart-loop forever with:
#     display name: simplex-chat: <stdin>: hGetLine: end of file
#
# We run simplex-chat in "execute one command then exit" mode (-e) and
# pipe the display name through stdin. After this one-shot invocation
# the profile exists on disk and the long-running service can use it.
set -euo pipefail

SIMPLEX_DATA="/var/lib/lifeos/simplex"
DB_PREFIX="${SIMPLEX_DATA}/bot"
SETUP_MARKER="${SIMPLEX_DATA}/.setup-done"
BOT_NAME="Axi"

# StateDirectory in the unit guarantees the dir exists, but this script
# is defensive — if somebody installs it elsewhere we still want it to
# work.
mkdir -p "$SIMPLEX_DATA"
chmod 0700 "$SIMPLEX_DATA"

if [ -f "$SETUP_MARKER" ] && [ -f "${DB_PREFIX}_chat.db" ]; then
    echo "[lifeos-simplex-setup] Already configured"
    exit 0
fi

echo "[lifeos-simplex-setup] Bootstrapping SimpleX profile '${BOT_NAME}'..."

# `-e /quit` makes simplex-chat execute "/quit" immediately and exit.
# Piping the display name on stdin satisfies the one-time profile prompt
# and leaves a usable database behind.
# `-y` auto-confirms database migrations so future upgrades don't block.
if ! printf '%s\n' "$BOT_NAME" | /usr/local/bin/simplex-chat \
        -d "$DB_PREFIX" \
        -y \
        -e "/quit" >/dev/null 2>&1; then
    # Some simplex-chat builds reject `/quit` as an unknown command —
    # in that case the profile is already created by the time the
    # command fails, and the service ExecStart will pick it up.
    echo "[lifeos-simplex-setup] bootstrap pass exited non-zero, continuing"
fi

if [ ! -f "${DB_PREFIX}_chat.db" ]; then
    echo "[lifeos-simplex-setup] FATAL: database was not created at ${DB_PREFIX}_chat.db" >&2
    exit 1
fi

touch "$SETUP_MARKER"
echo "[lifeos-simplex-setup] Setup complete — profile '${BOT_NAME}' ready"
