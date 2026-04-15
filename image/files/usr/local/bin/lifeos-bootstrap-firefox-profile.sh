#!/bin/sh
# LifeOS Firefox Profile Bootstrapper
#
# Ensures ~/.mozilla/firefox/lifeos.default/ exists as a real profile
# directory on first login, then writes profiles.ini pointing at it.
#
# System-wide policies.json (/etc/firefox/policies/policies.json and
# /usr/lib64/firefox/distribution/policies.json) already enforce DuckDuckGo,
# uBlock Origin, DoH, telemetry-off, tracking protection — those apply to
# EVERY profile regardless of name, so we don't duplicate them per-profile.
#
# This is idempotent: a marker file prevents re-running.
#
# Called by lifeos-firefox-profile.service (user-level oneshot) on first
# graphical login. Also safe to invoke manually.

set -eu

FF_DIR="$HOME/.mozilla/firefox"
PROFILE_DIR="$FF_DIR/lifeos.default"
MARKER="$PROFILE_DIR/.lifeos-bootstrap-done"
PROFILES_INI="$FF_DIR/profiles.ini"

# Already bootstrapped — nothing to do.
if [ -f "$MARKER" ]; then
    exit 0
fi

# Firefox must be available.
if ! command -v firefox >/dev/null 2>&1; then
    echo "[lifeos-firefox] firefox binary not found, skipping bootstrap" >&2
    exit 0
fi

# Never touch a running Firefox — it would corrupt the profile DB.
if pgrep -x firefox >/dev/null 2>&1; then
    echo "[lifeos-firefox] firefox is running, deferring bootstrap" >&2
    exit 0
fi

mkdir -p "$FF_DIR"

# Create the profile directory. Firefox itself populates prefs.js and the
# sqlite stores on first real launch — all we need is the directory to
# exist so profiles.ini resolves. We try `-CreateProfile` as a nicety
# (it seeds a times.json and may pre-create an invalidprefs.js), but
# fall back to a plain mkdir since headless -CreateProfile is unreliable
# on some Firefox builds (exits 0 without actually creating the dir).
if [ ! -d "$PROFILE_DIR" ]; then
    echo "[lifeos-firefox] Creating lifeos.default profile at $PROFILE_DIR"
    firefox --headless --no-remote \
        -CreateProfile "lifeos.default $PROFILE_DIR" \
        >/dev/null 2>&1 || true
    mkdir -p "$PROFILE_DIR"
fi

# Write profiles.ini so Firefox picks lifeos.default as the default profile.
# Force a clean rewrite — the /etc/profile.d helper keeps this in sync at
# every login in case Firefox rewrites it.
cat > "$PROFILES_INI" << 'INI'
[General]
StartWithLastProfile=1
Version=2

[Profile0]
Name=lifeos.default
IsRelative=1
Path=lifeos.default
Default=1
INI

# Mark bootstrap complete so we don't rerun.
touch "$MARKER"

echo "[lifeos-firefox] Bootstrap complete for lifeos.default"
