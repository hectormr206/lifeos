#!/bin/bash
# LifeOS Update Checker — runs daily via systemd timer.
# Checks if a new bootc image is available and notifies via Axi.
# Does NOT auto-apply — just informs the user.
#
# Also writes a cached state file at /var/lib/lifeos/update-state.json so the
# unprivileged user daemon (lifeosd) can report update availability without
# needing root to run `bootc status`.

set -euo pipefail

STATE_FILE="/var/lib/lifeos/last-update-check"
NOTIFY_SENT="/var/lib/lifeos/update-notify-sent"
CACHE_FILE="/var/lib/lifeos/update-state.json"
CACHE_TMP="/var/lib/lifeos/update-state.json.tmp"

mkdir -p /var/lib/lifeos

echo "[update-check] Checking for LifeOS updates..."

# Resolve current booted version from bootc status (best-effort)
CURRENT_VERSION="unknown"
if STATUS_JSON=$(bootc status --format json 2>/dev/null); then
    PARSED=$(printf '%s' "$STATUS_JSON" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
    v=d.get("status",{}).get("booted",{}).get("image",{}).get("version") \
        or d.get("status",{}).get("booted",{}).get("version") or ""
    print(v)
except Exception:
    print("")' 2>/dev/null || true)
    if [ -n "$PARSED" ]; then
        CURRENT_VERSION="$PARSED"
    fi
fi

write_cache() {
    local available="$1"
    local new_version="$2"
    local error="${3:-}"
    local checked_at
    checked_at=$(date -Iseconds)
    if [ -n "$error" ]; then
        jq -n \
            --arg cur "$CURRENT_VERSION" \
            --arg nv "$new_version" \
            --arg ts "$checked_at" \
            --arg err "$error" \
            --argjson av "$available" \
            '{available:$av, current_version:$cur, new_version:$nv, checked_at:$ts, error:$err}' \
            > "$CACHE_TMP"
    else
        jq -n \
            --arg cur "$CURRENT_VERSION" \
            --arg nv "$new_version" \
            --arg ts "$checked_at" \
            --argjson av "$available" \
            '{available:$av, current_version:$cur, new_version:$nv, checked_at:$ts}' \
            > "$CACHE_TMP"
    fi
    chmod 0644 "$CACHE_TMP"
    mv -f "$CACHE_TMP" "$CACHE_FILE"
}

# Run bootc upgrade check (dry-run). Capture exit code separately so a failed
# check (network, registry, auth) does NOT pin a false "available=true" in the
# cache.
set +e
UPDATE_OUTPUT=$(bootc upgrade --check 2>&1)
CHECK_RC=$?
set -e

if [ "$CHECK_RC" -ne 0 ]; then
    echo "[update-check] bootc upgrade --check failed (rc=$CHECK_RC): $UPDATE_OUTPUT" >&2
    # Do NOT clobber an existing cache with a spurious result. If there is no
    # cache yet, write a conservative "false" entry annotated with the error so
    # downstream readers can distinguish "nothing available" from "check failed".
    if [ ! -f "$CACHE_FILE" ]; then
        write_cache "false" "$CURRENT_VERSION" "check failed (rc=$CHECK_RC)"
    fi
    exit 0
fi

if echo "$UPDATE_OUTPUT" | grep -qi "no update available\|already at latest\|No changes"; then
    echo "[update-check] System is up to date"
    rm -f "$NOTIFY_SENT"
    date -Iseconds > "$STATE_FILE"
    write_cache "false" "$CURRENT_VERSION"
    exit 0
fi

# There's an update available
echo "[update-check] Update available!"
echo "$UPDATE_OUTPUT"

# Try to extract a version hint from the output (first token after "version")
NEW_VERSION="newer"
HINT=$(echo "$UPDATE_OUTPUT" | awk 'tolower($0) ~ /version/ {for (i=1;i<=NF;i++) if (tolower($i)=="version" && (i+1)<=NF) {print $(i+1); exit}}')
if [ -n "${HINT:-}" ]; then
    NEW_VERSION="$HINT"
fi

write_cache "true" "$NEW_VERSION"

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
