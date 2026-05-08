#!/bin/bash
# scripts/test-live.sh — Integration tests against running daemon
# Phase 8b: daemon API via Unix-domain socket (SO_PEERCRED auth).
set -euo pipefail

LIFEOS_API_SOCKET="${LIFEOS_API_SOCKET:-/run/lifeos/lifeosd.sock}"
TOKEN_FILE="/run/lifeos/bootstrap.token"

if [ ! -f "$TOKEN_FILE" ]; then
    echo "SKIP: lifeosd not running (no bootstrap token)"
    exit 0
fi

TOKEN=$(cat "$TOKEN_FILE")
ERRORS=0

check() {
    local desc="$1" method="$2" path="$3" expected_status="$4"
    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" -X "$method" \
        --unix-socket "${LIFEOS_API_SOCKET}" \
        -H "x-bootstrap-token: $TOKEN" "http://localhost${path}" 2>/dev/null || echo "000")
    if [ "$status" = "$expected_status" ]; then
        echo "  OK: $desc ($status)"
    else
        echo "  FAIL: $desc (expected $expected_status, got $status)"
        ERRORS=$((ERRORS + 1))
    fi
}

echo "=== Live Integration Tests ==="
check "Health endpoint" GET "/api/v1/health" "200"
check "System info" GET "/api/v1/system/info" "200"
check "LLM providers" GET "/api/v1/llm/providers" "200"
check "Task list" GET "/api/v1/tasks" "200"
check "Calendar today" GET "/api/v1/calendar/today" "200"
check "Game guard status" GET "/api/v1/game-guard/status" "200"
check "Messaging channels" GET "/api/v1/messaging/channels" "200"
check "Supervisor metrics" GET "/api/v1/supervisor/metrics" "200"

# Test unauthorized (no token) — connect via socket, omit token header
NOAUTH=$(curl -s -o /dev/null -w "%{http_code}" \
    --unix-socket "${LIFEOS_API_SOCKET}" \
    "http://localhost/api/v1/system/info" 2>/dev/null || echo "000")
if [ "$NOAUTH" = "401" ] || [ "$NOAUTH" = "403" ]; then
    echo "  OK: Auth enforcement works ($NOAUTH without token)"
else
    echo "  FAIL: Auth not enforced (got $NOAUTH without token)"
    ERRORS=$((ERRORS + 1))
fi

echo ""
if [ "$ERRORS" -eq 0 ]; then
    echo "ALL LIVE TESTS PASSED"
else
    echo "FAILED: $ERRORS tests"
    exit 1
fi
