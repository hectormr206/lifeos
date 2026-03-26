#!/bin/sh
# Generate LifeOS system sounds using sox.
# Called during image build. Produces short, subtle tones matching the Axi teal aesthetic.
# All sounds are optional — the system works fine without them.

set -eu

SOUND_DIR="/usr/share/sounds/lifeos/stereo"
mkdir -p "$SOUND_DIR"

if ! command -v sox >/dev/null 2>&1; then
    echo "WARN: sox not found, skipping sound generation"
    exit 0
fi

# Startup chime: two-tone ascending (C5 → E5), 1.5 seconds, gentle fade
sox -n "$SOUND_DIR/desktop-login.ogg" \
    synth 0.6 sine 523.25 fade 0.05 0.6 0.3 : \
    synth 0.6 sine 659.25 fade 0.05 0.6 0.4 \
    gain -12 2>/dev/null || true

# Notification: single soft ping (A5), 0.4 seconds
sox -n "$SOUND_DIR/message-new-instant.ogg" \
    synth 0.4 sine 880 fade 0.02 0.4 0.3 \
    gain -15 2>/dev/null || true

# Error: low tone (E3), 0.3 seconds
sox -n "$SOUND_DIR/dialog-error.ogg" \
    synth 0.3 sine 164.81 fade 0.02 0.3 0.2 \
    gain -10 2>/dev/null || true

# Warning: two quick tones (A4, A4), 0.5 seconds
sox -n "$SOUND_DIR/dialog-warning.ogg" \
    synth 0.15 sine 440 fade 0.01 0.15 0.05 : \
    synth 0.15 sine 440 fade 0.01 0.15 0.1 \
    gain -12 2>/dev/null || true

# Logout chime: descending (E5 → C5), 1 second
sox -n "$SOUND_DIR/desktop-logout.ogg" \
    synth 0.5 sine 659.25 fade 0.05 0.5 0.3 : \
    synth 0.5 sine 523.25 fade 0.05 0.5 0.4 \
    gain -12 2>/dev/null || true

echo "LifeOS sounds generated in $SOUND_DIR"
