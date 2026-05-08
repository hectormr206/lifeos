#!/bin/bash
# LifeOS Update Stager — fetches (stages) a new bootc image WITHOUT applying it.
# Runs weekly via lifeos-update-stage.timer (Sunday 04:00 + 30 min jitter).
#
# State file: /var/lib/lifeos/update-stage-state.json
#   Fields: staged (bool), staged_digest (str|null), staged_at (ISO8601|null),
#           last_stage_error (str|null), last_stage_attempt (ISO8601|null)
#
# Design contract:
#   - NEVER calls bootc upgrade --apply
#   - NEVER triggers a reboot
#   - Idempotent: if staged_digest already matches remote, exits 0 with no-op log
#   - On failure: preserves prior staged_digest/staged_at; sets staged=false + error
#   - set -euo pipefail; NO set -x (credential leakage risk)
#
# Environment override (for testing):
#   LIFEOS_STATE_DIR  — override /var/lib/lifeos (default)
set -euo pipefail

STATE_DIR="${LIFEOS_STATE_DIR:-/var/lib/lifeos}"
STATE_FILE="${STATE_DIR}/update-state.json"
STAGE_STATE_FILE="${STATE_DIR}/update-stage-state.json"
STAGE_TMP="${STAGE_STATE_FILE}.tmp"
LAST_NOTIFIED_ERROR="${STATE_DIR}/stage-last-notified-error"
BOOTSTRAP_TOKEN_FILE="${STATE_DIR}/bootstrap-token"

mkdir -p "$STATE_DIR"

log() { echo "[update-stage] $*"; }

# ─── Notification helpers ─────────────────────────────────────────────────────

notify_desktop() {
    local summary="$1"
    local body="$2"
    local icon="${3:-software-update-available}"
    if command -v notify-send >/dev/null 2>&1; then
        DESKTOP_USER=$(loginctl list-users --no-legend 2>/dev/null | awk 'NR==1{print $2}' || true)
        if [ -n "${DESKTOP_USER:-}" ]; then
            su - "$DESKTOP_USER" -c \
                "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\$(id -u)/bus \
                notify-send '$summary' '$body' --icon=$icon" 2>/dev/null || true
        fi
    fi
}

notify_axi() {
    local message="$1"
    local severity="${2:-info}"
    local token=""
    token=$(cat "$BOOTSTRAP_TOKEN_FILE" 2>/dev/null || echo none)
    # Phase 8b: daemon API via Unix-domain socket (SO_PEERCRED auth).
    local api_socket
    api_socket="${LIFEOS_API_SOCKET:-/run/lifeos/lifeosd.sock}"
    if curl -sf \
        --unix-socket "${api_socket}" \
        -H "x-bootstrap-token: $token" \
        "http://localhost/api/v1/health" >/dev/null 2>&1; then
        curl -sf -X POST \
            --unix-socket "${api_socket}" \
            -H "Content-Type: application/json" \
            -H "x-bootstrap-token: $token" \
            -d "{\"message\": \"$message\", \"severity\": \"$severity\"}" \
            "http://localhost/api/v1/notifications" 2>/dev/null || true
    fi
}

# Edge-triggered notification: only notify when error state changes.
notify_error_if_changed() {
    local error_msg="$1"
    local last_error=""
    last_error=$(cat "$LAST_NOTIFIED_ERROR" 2>/dev/null || echo "")
    if [ "$last_error" != "$error_msg" ]; then
        notify_desktop "LifeOS Update Staging Failed" "Update staging failed — see logs" dialog-error
        notify_axi "LifeOS update staging failed: $error_msg" "error"
        echo "$error_msg" > "$LAST_NOTIFIED_ERROR"
    fi
}

notify_success_if_changed() {
    if [ -f "$LAST_NOTIFIED_ERROR" ]; then
        notify_desktop "LifeOS Update Staged" "Update staged — reboot to activate" software-update-available
        notify_axi "LifeOS update staged successfully — reboot to activate" "info"
        rm -f "$LAST_NOTIFIED_ERROR"
    fi
}

# ─── State file helpers ───────────────────────────────────────────────────────

# Read a field from stage state JSON; returns empty string on missing/null.
read_stage_field() {
    local field="$1"
    if [ ! -f "$STAGE_STATE_FILE" ]; then echo ""; return; fi
    python3 -c "
import json, sys
try:
    d = json.load(open('$STAGE_STATE_FILE'))
    v = d.get('$field')
    print(v if v is not None else '')
except Exception:
    print('')
" 2>/dev/null || echo ""
}

# Read a field from check state JSON.
read_check_field() {
    local field="$1"
    if [ ! -f "$STATE_FILE" ]; then echo ""; return; fi
    python3 -c "
import json, sys
try:
    d = json.load(open('$STATE_FILE'))
    v = d.get('$field')
    print(v if v is not None else '')
except Exception:
    print('')
" 2>/dev/null || echo ""
}

write_stage_state_success() {
    local digest="$1"
    local staged_at="$2"
    python3 -c "
import json, os
path = '$STAGE_STATE_FILE'
tmp  = '${STAGE_TMP}'
state = {}
if os.path.exists(path):
    try:
        state = json.load(open(path))
    except Exception:
        state = {}
state['staged']            = True
state['staged_digest']     = '$digest'
state['staged_at']         = '$staged_at'
state['last_stage_attempt']= '$staged_at'
state['last_stage_error']  = None
with open(tmp, 'w') as f:
    json.dump(state, f, indent=2)
    f.write('\n')
os.chmod(tmp, 0o644)
os.replace(tmp, path)
"
}

write_stage_state_failure() {
    local error_msg="$1"
    local attempt_at="$2"
    python3 -c "
import json, os
path = '$STAGE_STATE_FILE'
tmp  = '${STAGE_TMP}'
state = {}
if os.path.exists(path):
    try:
        state = json.load(open(path))
    except Exception:
        state = {}
# Preserve prior staged_digest / staged_at on failure
state['staged']             = False
state['last_stage_attempt'] = '$attempt_at'
state['last_stage_error']   = $(python3 -c "import json; print(json.dumps('$error_msg'))")
# Do NOT set staged_digest or staged_at — preserve whatever was there
with open(tmp, 'w') as f:
    json.dump(state, f, indent=2)
    f.write('\n')
os.chmod(tmp, 0o644)
os.replace(tmp, path)
"
}

# ─── Main logic ───────────────────────────────────────────────────────────────

log "Starting update stage check..."

# 1. Check if anything is available at all (short-circuit)
available=$(read_check_field "available")
if [ "$available" = "False" ] || [ "$available" = "false" ]; then
    log "Nothing to stage — update-check reports no update available."
    exit 0
fi

# 2. Get remote digest (from check state; fallback: run check)
remote_digest=$(read_check_field "remote_digest")

# 3. Idempotency: if already staged at same digest, skip
if [ -n "$remote_digest" ]; then
    staged_digest=$(read_stage_field "staged_digest")
    if [ -n "$staged_digest" ] && [ "$staged_digest" = "$remote_digest" ]; then
        log "Already staged, no-op (staged_digest=$staged_digest matches remote)."
        exit 0
    fi
fi

log "Staging new bootc image (bootc upgrade, no --apply)..."

# 4. Run bootc upgrade (fetch only, no apply). Capture stderr for error reporting.
attempt_at=$(date -Iseconds)
BOOTC_STDERR_TMP=$(mktemp)
rc=0
bootc upgrade 2>"$BOOTC_STDERR_TMP" || rc=$?

if [ "$rc" -ne 0 ]; then
    stderr_snippet=$(head -c 2048 "$BOOTC_STDERR_TMP" 2>/dev/null || echo "unknown error")
    rm -f "$BOOTC_STDERR_TMP"

    # Categorize error
    error_category="unknown"
    if echo "$stderr_snippet" | grep -qi "network\|connect\|dns\|timeout"; then
        error_category="network"
    elif echo "$stderr_snippet" | grep -qi "registry\|auth\|unauthorized\|manifest"; then
        error_category="registry"
    elif echo "$stderr_snippet" | grep -qi "disk\|space\|no space\|quota"; then
        error_category="disk_full"
    fi

    error_msg="${error_category}:rc=${rc}:${stderr_snippet}"

    log "bootc upgrade failed (rc=$rc, category=$error_category)"
    write_stage_state_failure "$error_msg" "$attempt_at"
    notify_error_if_changed "$error_category: bootc upgrade failed (rc=$rc)"
    exit "$rc"
fi
rm -f "$BOOTC_STDERR_TMP"

# 5. Post-condition: read staged digest from bootc status
log "bootc upgrade succeeded, reading staged digest..."
staged_digest=""
if STATUS_JSON=$(bootc status --format json 2>/dev/null); then
    staged_digest=$(python3 -c "
import json, sys
try:
    d = json.loads('''$STATUS_JSON''')
    staged = d.get('status', {}).get('staged', {})
    digest = (staged.get('image', {}) or {}).get('image', {})
    if isinstance(digest, dict):
        digest = digest.get('digest', '')
    elif not isinstance(digest, str):
        digest = ''
    print(digest or '')
except Exception as e:
    print('')
" 2>/dev/null || echo "")
fi

if [ -z "$staged_digest" ]; then
    # Fallback: use remote_digest from check state
    staged_digest="$remote_digest"
fi

staged_at=$(date -Iseconds)
write_stage_state_success "$staged_digest" "$staged_at"

log "Stage complete: staged_digest=$staged_digest staged_at=$staged_at"
notify_success_if_changed

exit 0
