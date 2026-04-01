#!/bin/bash
# LifeOS Update Checker — runs daily via systemd timer.
# Checks if a new bootc image is available and notifies via Axi.
# Does NOT auto-apply — just informs the user.

set -euo pipefail

STATE_FILE="/var/lib/lifeos/last-update-check"
NOTIFY_SENT="/var/lib/lifeos/update-notify-sent"

mkdir -p /var/lib/lifeos

echo "[update-check] Checking for LifeOS updates..."

# Run bootc upgrade check (dry-run)
UPDATE_OUTPUT=$(bootc upgrade --check 2>&1) || true

if echo "$UPDATE_OUTPUT" | grep -qi "no update available\|already at latest\|No changes"; then
    echo "[update-check] System is up to date"
    rm -f "$NOTIFY_SENT"
    date -Iseconds > "$STATE_FILE"
    exit 0
fi

# There's an update available
echo "[update-check] Update available!"
echo "$UPDATE_OUTPUT"

# Only notify once per available update (don't spam)
if [ -f "$NOTIFY_SENT" ]; then
    echo "[update-check] Notification already sent for this update"
    exit 0
fi

# Notify via desktop notification (works for both COSMIC and GNOME)
SUMMARY="LifeOS Update Available"
BODY="A new LifeOS image is ready. Run 'life update' or ask Axi to update."

# Try notify-send for desktop notification
if command -v notify-send >/dev/null 2>&1; then
    # Run as the desktop user (not root)
    DESKTOP_USER=$(loginctl list-users --no-legend 2>/dev/null | awk 'NR==1{print $2}')
    if [ -n "$DESKTOP_USER" ]; then
        su - "$DESKTOP_USER" -c "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\$(id -u)/bus notify-send '$SUMMARY' '$BODY' --icon=software-update-available" 2>/dev/null || true
    fi
fi

# Also notify via Axi REST API if daemon is running
if curl -sf -H "x-bootstrap-token: $(cat /var/lib/lifeos/bootstrap-token 2>/dev/null || echo none)" \
    http://127.0.0.1:8081/api/v1/health >/dev/null 2>&1; then
    curl -sf -X POST \
        -H "Content-Type: application/json" \
        -H "x-bootstrap-token: $(cat /var/lib/lifeos/bootstrap-token 2>/dev/null || echo none)" \
        -d "{\"message\": \"$BODY\", \"severity\": \"info\"}" \
        http://127.0.0.1:8081/api/v1/notifications 2>/dev/null || true
fi

date -Iseconds > "$STATE_FILE"
touch "$NOTIFY_SENT"
echo "[update-check] Notification sent"
