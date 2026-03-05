#!/usr/bin/env bash
# Runtime security regression tests for LifeOS daemon (Fase 0).
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -n "${LIFEOS_DAEMON_BIN:-}" ]]; then
    DAEMON_BIN="${LIFEOS_DAEMON_BIN}"
elif [[ -x "${PROJECT_ROOT}/target/release/lifeosd" ]]; then
    DAEMON_BIN="${PROJECT_ROOT}/target/release/lifeosd"
else
    DAEMON_BIN="${PROJECT_ROOT}/daemon/target/release/lifeosd"
fi
TMP_RUNTIME="$(mktemp -d)"
TMP_HOME="$(mktemp -d)"
PORT="${LIFEOS_SECURITY_TEST_PORT:-8081}"
BASE_URL="http://127.0.0.1:${PORT}"

PASS_COUNT=0
FAIL_COUNT=0

cleanup() {
    if [[ -n "${DAEMON_PID:-}" ]]; then
        kill "${DAEMON_PID}" >/dev/null 2>&1 || true
        wait "${DAEMON_PID}" 2>/dev/null || true
    fi
    rm -rf "${TMP_RUNTIME}" "${TMP_HOME}"
}
trap cleanup EXIT

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "[PASS] $1"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "[FAIL] $1"
}

assert_http_code() {
    local description="$1"
    local expected="$2"
    local code="$3"
    if [[ "${code}" == "${expected}" ]]; then
        pass "${description} (HTTP ${code})"
    else
        fail "${description} (expected ${expected}, got ${code})"
    fi
}

http_code() {
    local code
    code="$(curl -s -o /dev/null -w "%{http_code}" "$@" || true)"
    if [[ "${code}" =~ ^[0-9]{3}$ ]]; then
        echo "${code}"
    else
        echo "000"
    fi
}

if [[ ! -x "${DAEMON_BIN}" ]]; then
    echo "Daemon binary not found at ${DAEMON_BIN}"
    echo "Build it first: (cd daemon && cargo build --release)"
    exit 1
fi

echo "==============================================="
echo " LifeOS Runtime Security Regression Suite"
echo "==============================================="

echo "Starting daemon in isolated runtime..."
(
    cd "${PROJECT_ROOT}/daemon"
    LIFEOS_RUNTIME_DIR="${TMP_RUNTIME}" \
    HOME="${TMP_HOME}" \
    RUST_LOG=error \
    "${DAEMON_BIN}" >/tmp/lifeosd-security-tests.log 2>&1
) &
DAEMON_PID=$!

BOOTSTRAP_TOKEN=""
for _ in $(seq 1 50); do
    if [[ -f "${TMP_RUNTIME}/bootstrap.token" ]]; then
        BOOTSTRAP_TOKEN="$(cat "${TMP_RUNTIME}/bootstrap.token")"
        break
    fi
    sleep 0.2
done

if [[ -z "${BOOTSTRAP_TOKEN}" ]]; then
    echo "Bootstrap token was not generated."
    echo "Daemon logs:"
    sed -n '1,200p' /tmp/lifeosd-security-tests.log || true
    exit 1
fi

echo "Bootstrap token generated."

# Wait until the HTTP API is reachable to avoid startup race flakiness.
readiness_code="000"
for _ in $(seq 1 50); do
    readiness_code="$(http_code "${BASE_URL}/api/v1/system/status")"
    if [[ "${readiness_code}" != "000" ]]; then
        break
    fi
    sleep 0.2
done

if [[ "${readiness_code}" == "000" ]]; then
    echo "Daemon HTTP API did not become reachable in time."
    echo "Daemon logs:"
    sed -n '1,200p' /tmp/lifeosd-security-tests.log || true
    exit 1
fi

# 1) Unauthorized request must be blocked
code_unauth="$(http_code "${BASE_URL}/api/v1/system/status")"
assert_http_code "Missing bootstrap token is rejected" "401" "${code_unauth}"

# 2) Wrong token must be blocked
code_wrong="$(http_code -H "x-bootstrap-token: wrong" "${BASE_URL}/api/v1/system/status")"
assert_http_code "Invalid bootstrap token is rejected" "401" "${code_wrong}"

# 3) Correct token grants access
code_ok="$(http_code -H "x-bootstrap-token: ${BOOTSTRAP_TOKEN}" "${BASE_URL}/api/v1/system/status")"
assert_http_code "Valid bootstrap token grants access" "200" "${code_ok}"

# 4) Path traversal style command injection is rejected by allowlist
payload='{"command":"../../../../etc/shadow","args":[]}'
code_path="$(http_code \
    -X POST "${BASE_URL}/api/v1/system/command" \
    -H "Content-Type: application/json" \
    -H "x-bootstrap-token: ${BOOTSTRAP_TOKEN}" \
    -d "${payload}")"
assert_http_code "Path traversal command is blocked" "403" "${code_path}"

# 5) AI endpoint fails closed when AI service is offline
chat_payload='{"message":"hello","stream":false}'
code_ai="$(http_code \
    -X POST "${BASE_URL}/api/v1/ai/chat" \
    -H "Content-Type: application/json" \
    -H "x-bootstrap-token: ${BOOTSTRAP_TOKEN}" \
    -d "${chat_payload}")"
if [[ "${code_ai}" == "503" || "${code_ai}" == "502" ]]; then
    pass "AI chat endpoint fails safely when backend is unavailable (HTTP ${code_ai})"
else
    fail "AI chat endpoint returned unexpected status (expected 503/502, got ${code_ai})"
fi

echo
echo "Summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
if [[ ${FAIL_COUNT} -ne 0 ]]; then
    echo "Security regression suite failed."
    exit 1
fi

echo "Security regression suite passed."
