#!/bin/bash
# LifeOS Sentinel — independent watchdog for lifeosd.
# Runs as a separate systemd service. Monitors lifeosd health
# and escalates through restart → repair → factory reset → alert.
#
# This script has NO dependencies on lifeosd code, config, or state.
# It is as simple as possible so it cannot break.
set -euo pipefail

API="http://127.0.0.1:8081"
CHECK_INTERVAL=30
FAIL_COUNT=0
MAX_LOG_LINES=100
LOG_FILE="/var/log/lifeos/sentinel.log"

log() {
    echo "$(date -Iseconds) [sentinel] $*" | tee -a "$LOG_FILE" 2>/dev/null || true
    # Keep log file small
    if [ -f "$LOG_FILE" ] && [ "$(wc -l < "$LOG_FILE")" -gt "$MAX_LOG_LINES" ]; then
        tail -n "$MAX_LOG_LINES" "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
    fi
}

check_health() {
    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$API/api/v1/health" 2>/dev/null || echo "000")
    echo "$status"
}

send_telegram_alert() {
    local message="$1"
    # Read Telegram config directly from env file (bypass lifeosd)
    local token=""
    local chat_id=""
    if [ -f /etc/lifeos/llm-providers.env ]; then
        token=$(grep "^LIFEOS_TELEGRAM_BOT_TOKEN=" /etc/lifeos/llm-providers.env 2>/dev/null | cut -d= -f2 || true)
        chat_id=$(grep "^LIFEOS_TELEGRAM_CHAT_ID=" /etc/lifeos/llm-providers.env 2>/dev/null | cut -d= -f2 || true)
    fi
    if [ -n "$token" ] && [ -n "$chat_id" ]; then
        curl -s -X POST "https://api.telegram.org/bot${token}/sendMessage" \
            -d "chat_id=${chat_id}" \
            -d "text=${message}" \
            --max-time 10 2>/dev/null || true
    fi
}

mkdir -p "$(dirname "$LOG_FILE")"
log "Sentinel started — monitoring lifeosd at $API"

while true; do
    sleep "$CHECK_INTERVAL"

    STATUS=$(check_health)

    if [ "$STATUS" = "200" ]; then
        if [ "$FAIL_COUNT" -gt 0 ]; then
            log "lifeosd recovered after $FAIL_COUNT failures"
        fi
        FAIL_COUNT=0
        continue
    fi

    FAIL_COUNT=$((FAIL_COUNT + 1))
    log "Health check failed (HTTP $STATUS) — failure #$FAIL_COUNT"

    if [ "$FAIL_COUNT" -eq 1 ]; then
        log "Warning: lifeosd may be unresponsive"
    fi

    if [ "$FAIL_COUNT" -eq 3 ]; then
        log "ESCALATION: Restarting lifeosd"
        systemctl restart lifeosd 2>/dev/null || log "Failed to restart lifeosd"
    fi

    if [ "$FAIL_COUNT" -eq 5 ]; then
        log "ESCALATION: Running life doctor --repair"
        /usr/bin/life doctor --repair 2>/dev/null || log "Doctor repair failed"
        systemctl restart lifeosd 2>/dev/null || true
    fi

    if [ "$FAIL_COUNT" -eq 10 ]; then
        log "CRITICAL: lifeosd unable to recover after 10 failures"
        send_telegram_alert "⚠️ Axi no puede recuperarse despues de 10 intentos. El sentinel ha agotado las opciones de reparacion automatica. Revisa el sistema manualmente."
        # Reset counter to avoid spamming alerts
        FAIL_COUNT=0
        # Wait longer before next cycle
        sleep 300
    fi
done
