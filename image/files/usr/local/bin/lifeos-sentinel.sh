#!/bin/bash
# LifeOS Sentinel — independent watchdog for lifeosd.
# Runs as a separate systemd service. Monitors lifeosd health
# and escalates through restart → repair → structured recovery → alert.
#
# This script has NO dependencies on lifeosd code, config, or state.
# It is as simple as possible so it cannot break.
set -euo pipefail

API="http://127.0.0.1:8081"
CHECK_INTERVAL=30
FAIL_COUNT=0
MAX_LOG_LINES=100
LOG_FILE="/var/log/lifeos/sentinel.log"
DISK_THRESHOLD=95
MEMORY_THRESHOLD=95
LIFEOS_PRIMARY_USER="${LIFEOS_PRIMARY_USER:-lifeos}"
LIFEOS_PRIMARY_UID="${LIFEOS_PRIMARY_UID:-1000}"

user_systemctl() {
    local runtime_dir="/run/user/${LIFEOS_PRIMARY_UID}"
    local user_bus="${runtime_dir}/bus"

    if ! command -v runuser >/dev/null 2>&1; then
        return 1
    fi

    if [ ! -S "$user_bus" ]; then
        return 1
    fi

    runuser -u "$LIFEOS_PRIMARY_USER" -- \
        env XDG_RUNTIME_DIR="$runtime_dir" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=${user_bus}" \
            systemctl --user "$@"
}

restart_lifeosd() {
    # Canonical path after Phase 3 of the architecture pivot: restart the
    # system-scope Quadlet `lifeos-lifeosd.service`. The legacy user-scope
    # `lifeosd.service` no longer exists.
    systemctl restart lifeos-lifeosd.service 2>/dev/null || \
        log "Failed to restart lifeos-lifeosd.service"
}

log() {
    echo "$(date -Iseconds) [sentinel] $*" | tee -a "$LOG_FILE" 2>/dev/null || true
    # Keep log file small
    if [ -f "$LOG_FILE" ] && [ "$(wc -l < "$LOG_FILE")" -gt "$MAX_LOG_LINES" ]; then
        tail -n "$MAX_LOG_LINES" "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
    fi
}

read_bootstrap_token() {
    # Phase 3 of architecture pivot: lifeos-lifeosd is now a system Quadlet
    # with LIFEOS_RUNTIME_DIR=/run/lifeos (bind-mounted host↔container so
    # both sides see the same token file). The legacy user-scope path
    # /run/user/<uid>/lifeos/bootstrap.token is checked second as a
    # rollback compatibility shim — it would only match if the operator
    # rolled back to a pre-Phase-3 deployment that still ran lifeosd as a
    # user service.
    for token_path in \
        "/run/lifeos/bootstrap.token" \
        "/run/user/${LIFEOS_PRIMARY_UID}/lifeos/bootstrap.token"
    do
        if [ -r "$token_path" ]; then
            cat "$token_path" 2>/dev/null
            return
        fi
    done
}

check_health() {
    # /api/v1/health is behind the bootstrap-token middleware. Sentinel
    # runs as root (system service) and reads the token from the user's
    # runtime dir each probe, so rotated tokens are picked up without
    # needing a sentinel restart. If the token is missing (daemon not
    # yet up) treat that as a probe failure so the escalation ladder
    # still runs.
    local token
    token="$(read_bootstrap_token)"
    if [ -z "$token" ]; then
        echo "000"
        return
    fi
    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time 5 \
        -H "x-bootstrap-token: ${token}" \
        "$API/api/v1/health" 2>/dev/null || echo "000")
    echo "$status"
}

# Returns 0 (true) if /var has enough disk space, 1 if critically full.
check_disk_space() {
    local usage
    usage=$(df /var 2>/dev/null | awk 'NR==2 {gsub(/%/,""); print $5}')
    if [ -z "$usage" ]; then
        # Cannot determine — assume ok so we don't block recovery
        return 0
    fi
    if [ "$usage" -ge "$DISK_THRESHOLD" ]; then
        log "DISK CRITICAL: /var is ${usage}% full (threshold: ${DISK_THRESHOLD}%)"
        return 1
    fi
    return 0
}

# Checks free memory. If >95% used, tries to free RAM by stopping llama-server.
check_memory() {
    local mem_total mem_available pct_used
    mem_total=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo "0")
    mem_available=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo "0")
    if [ "$mem_total" -eq 0 ]; then
        return 0
    fi
    pct_used=$(( (mem_total - mem_available) * 100 / mem_total ))
    if [ "$pct_used" -ge "$MEMORY_THRESHOLD" ]; then
        log "MEMORY CRITICAL: ${pct_used}% used — stopping llama-server to free RAM"
        systemctl stop lifeos-llama-server.service 2>/dev/null || true
        # Brief pause to let memory settle
        sleep 2
    fi
}

# Collect recent journal logs for debugging context in alerts.
collect_recent_logs() {
    local recent_logs
    recent_logs=$(journalctl -u lifeos-lifeosd -n 5 --no-pager 2>/dev/null || echo "no logs")
    echo "$recent_logs"
}

send_critical_alert() {
    # Telegram bridge removed — emit alert to journal/log only.
    # Future: route to SimpleX or desktop notification once a
    # system-level alerting channel is wired in.
    local message="$1"
    log "ALERT: ${message}"
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
        # Check disk space before attempting restart — if disk is full, restarting won't help
        if ! check_disk_space; then
            local_logs=$(collect_recent_logs)
            send_critical_alert "⚠️ Sentinel: /var esta >=${DISK_THRESHOLD}% lleno. Reiniciar no ayudara. Libera espacio manualmente.

Logs recientes:
${local_logs}"
            # Skip the restart, but keep counting failures
        else
            check_memory
            log "ESCALATION: Restarting lifeosd"
            restart_lifeosd
        fi
    fi

    if [ "$FAIL_COUNT" -eq 5 ]; then
        if check_disk_space; then
            check_memory
            log "ESCALATION: Running life doctor --repair"
            /usr/bin/life doctor --repair 2>/dev/null || log "Doctor repair failed"
            restart_lifeosd
        fi
    fi

    if [ "$FAIL_COUNT" -eq 10 ]; then
        log "CRITICAL: Attempting structured recovery"

        # Step 1: Stop llama-server to free GPU/RAM
        log "Recovery step 1: stopping llama-server"
        systemctl stop lifeos-llama-server.service 2>/dev/null || true

        # Step 2: Clear temporary files
        log "Recovery step 2: clearing /tmp/lifeos-* temporary files"
        rm -rf /tmp/lifeos-* 2>/dev/null || true

        # Step 3: Full daemon restart with environment reset
        log "Recovery step 3: full daemon restart with reset-failed"
        systemctl reset-failed lifeos-lifeosd.service 2>/dev/null || true
        restart_lifeosd

        # Step 4: Wait and check if recovery worked
        sleep 10
        RECOVERY_STATUS=$(check_health)
        if [ "$RECOVERY_STATUS" = "200" ]; then
            log "Structured recovery succeeded — lifeosd is back"
            FAIL_COUNT=0
            continue
        fi

        # Recovery failed — alert with debug context
        log "CRITICAL: lifeosd unable to recover after structured recovery"
        local_logs=$(collect_recent_logs)
        send_critical_alert "⚠️ Axi no puede recuperarse despues de 10 intentos + recuperacion estructurada.

Pasos ejecutados:
1. llama-server detenido
2. /tmp/lifeos-* limpiados
3. Reinicio completo con reset-failed

Logs recientes:
${local_logs}

Revisa el sistema manualmente."
        # Reset counter to avoid spamming alerts
        FAIL_COUNT=0
        # Wait longer before next cycle
        sleep 300
    fi
done
