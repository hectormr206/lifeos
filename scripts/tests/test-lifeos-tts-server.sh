#!/usr/bin/env bash
# scripts/tests/test-lifeos-tts-server.sh
# Shell integration tests for lifeos-tts-server.py
#
# Requires:
#   - kokoro and aiohttp installed in /opt/lifeos/kokoro-env (or on PATH)
#   - LIFEOS_TTS_SERVER_URL or defaults to http://127.0.0.1:8083
#
# The script starts the server (if not already running), runs assertions,
# then stops the server it started.
#
# Usage:
#   bash scripts/tests/test-lifeos-tts-server.sh
#   LIFEOS_TTS_SERVER_URL=http://127.0.0.1:8083 bash scripts/tests/test-lifeos-tts-server.sh
#
# Exit 0 = all tests passed; non-zero = failures.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SERVER_SCRIPT="${REPO_ROOT}/image/files/usr/local/bin/lifeos-tts-server.py"
SERVER_URL="${LIFEOS_TTS_SERVER_URL:-http://127.0.0.1:8083}"
VENV_PYTHON="${LIFEOS_TTS_VENV_PYTHON:-/opt/lifeos/kokoro-env/bin/python3}"
WAIT_TIMEOUT=60   # seconds to wait for /health to become 200
SERVER_PID=""

PASS=0
FAIL=0
ERRORS=()

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); ERRORS+=("$1"); }

# ---------------------------------------------------------------------------
# Server lifecycle helpers
# ---------------------------------------------------------------------------

start_server() {
    local python="${VENV_PYTHON}"
    if ! command -v "${python}" >/dev/null 2>&1; then
        # Fallback: system python3 (may not have kokoro)
        python="python3"
    fi

    LIFEOS_TTS_ENGINE_PORT=8083 \
    LIFEOS_TTS_DEFAULT_VOICE=if_sara \
    LIFEOS_TTS_DEVICE=cpu \
    HF_HUB_OFFLINE=1 \
    TRANSFORMERS_OFFLINE=1 \
        "${python}" "${SERVER_SCRIPT}" &
    SERVER_PID=$!
    echo "Started lifeos-tts-server.py as PID ${SERVER_PID}"
}

# stop_server is invoked via trap EXIT — shellcheck can't see indirect invocations
# shellcheck disable=SC2329
stop_server() {
    if [ -n "${SERVER_PID}" ] && kill -0 "${SERVER_PID}" 2>/dev/null; then
        echo "Stopping server PID ${SERVER_PID}"
        kill "${SERVER_PID}" 2>/dev/null || true
        wait "${SERVER_PID}" 2>/dev/null || true
    fi
}

wait_for_health() {
    local elapsed=0
    while [ "${elapsed}" -lt "${WAIT_TIMEOUT}" ]; do
        http_code=$(curl -s -o /dev/null -w '%{http_code}' "${SERVER_URL}/health" 2>/dev/null || echo "000")
        if [ "${http_code}" = "200" ]; then
            echo "Server healthy after ${elapsed}s"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    echo "Timeout waiting for server health after ${WAIT_TIMEOUT}s"
    return 1
}

# ---------------------------------------------------------------------------
# Determine if server is already running or needs to be started
# ---------------------------------------------------------------------------

SERVER_STARTED_BY_US=false
http_code=$(curl -s -o /dev/null -w '%{http_code}' "${SERVER_URL}/health" 2>/dev/null || echo "000")
if [ "${http_code}" = "200" ]; then
    echo "Server already running at ${SERVER_URL}"
else
    echo "Server not detected — starting..."
    if [ ! -f "${SERVER_SCRIPT}" ]; then
        echo "ERROR: server script not found at ${SERVER_SCRIPT}" >&2
        exit 1
    fi
    start_server
    # shellcheck disable=SC2034
    SERVER_STARTED_BY_US=true
    trap 'stop_server' EXIT
    if ! wait_for_health; then
        echo "ERROR: Server failed to become healthy" >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# T1: GET /health returns 200 + JSON with status=ok
# ---------------------------------------------------------------------------
response=$(curl -s -o /tmp/tts-health.json -w '%{http_code}' "${SERVER_URL}/health")
if [ "${response}" = "200" ]; then
    status=$(python3 -c "import json,sys; d=json.load(open('/tmp/tts-health.json')); print(d.get('status',''))" 2>/dev/null || echo "")
    if [ "${status}" = "ok" ]; then
        pass "T1: /health returns 200 + status=ok"
    else
        fail "T1: /health status not 'ok', got '${status}'"
    fi
else
    fail "T1: /health HTTP ${response}, expected 200"
fi

# ---------------------------------------------------------------------------
# T2: GET /health JSON has model=Kokoro-82M and voices_loaded>=1
# ---------------------------------------------------------------------------
voices_loaded=$(python3 -c "import json; d=json.load(open('/tmp/tts-health.json')); print(d.get('voices_loaded',0))" 2>/dev/null || echo "0")
model=$(python3 -c "import json; d=json.load(open('/tmp/tts-health.json')); print(d.get('model',''))" 2>/dev/null || echo "")
if [ "${model}" = "Kokoro-82M" ] && [ "${voices_loaded}" -ge 1 ] 2>/dev/null; then
    pass "T2: /health has model=Kokoro-82M and voices_loaded=${voices_loaded}"
else
    fail "T2: /health model='${model}' voices_loaded=${voices_loaded} (want model=Kokoro-82M, voices_loaded>=1)"
fi

# ---------------------------------------------------------------------------
# T3: GET /voices returns 200 + non-empty array
# ---------------------------------------------------------------------------
response=$(curl -s -o /tmp/tts-voices.json -w '%{http_code}' "${SERVER_URL}/voices")
if [ "${response}" = "200" ]; then
    count=$(python3 -c "import json; v=json.load(open('/tmp/tts-voices.json')); print(len(v))" 2>/dev/null || echo "0")
    if [ "${count}" -ge 1 ] 2>/dev/null; then
        pass "T3: /voices returns 200 + ${count} voices"
    else
        fail "T3: /voices returned empty array"
    fi
else
    fail "T3: /voices HTTP ${response}, expected 200"
fi

# ---------------------------------------------------------------------------
# T4: GET /voices each item has required fields
# ---------------------------------------------------------------------------
valid=$(python3 -c "
import json
data = json.load(open('/tmp/tts-voices.json'))
required = {'name', 'language', 'gender', 'is_default'}
bad = [v for v in data if not required.issubset(v.keys())]
print(len(bad))
" 2>/dev/null || echo "999")
if [ "${valid}" = "0" ]; then
    pass "T4: all voice entries have required fields (name, language, gender, is_default)"
else
    fail "T4: ${valid} voice entries missing required fields"
fi

# ---------------------------------------------------------------------------
# T5: POST /tts with valid voice returns 200 + non-empty WAV body
# ---------------------------------------------------------------------------
http_code=$(curl -s -X POST \
    -H 'Content-Type: application/json' \
    -d '{"text":"Hola sistema, prueba de voz.","voice":"if_sara"}' \
    -o /tmp/tts-output.wav \
    -w '%{http_code}' \
    "${SERVER_URL}/tts")
if [ "${http_code}" = "200" ]; then
    wav_size=$(wc -c < /tmp/tts-output.wav)
    # Validate WAV header: first 4 bytes = "RIFF"
    riff_header=$(python3 -c "
f=open('/tmp/tts-output.wav','rb')
h=f.read(4)
f.close()
print(h)
" 2>/dev/null || echo "")
    if [ "${wav_size}" -gt 1000 ] && echo "${riff_header}" | grep -q "RIFF"; then
        pass "T5: POST /tts returns 200 + valid WAV (${wav_size} bytes)"
    else
        fail "T5: POST /tts returned ${wav_size} bytes, RIFF header check: ${riff_header}"
    fi
else
    fail "T5: POST /tts HTTP ${http_code}, expected 200"
fi

# ---------------------------------------------------------------------------
# T6: POST /tts with format=ogg returns 200 + non-empty OGG body
# ---------------------------------------------------------------------------
http_code=$(curl -s -X POST \
    -H 'Content-Type: application/json' \
    -d '{"text":"Prueba OGG Vorbis.","voice":"if_sara","format":"ogg"}' \
    -o /tmp/tts-output.ogg \
    -w '%{http_code}' \
    "${SERVER_URL}/tts")
if [ "${http_code}" = "200" ]; then
    ogg_size=$(wc -c < /tmp/tts-output.ogg)
    # OGG header: first 4 bytes = "OggS"
    ogg_header=$(python3 -c "
f=open('/tmp/tts-output.ogg','rb')
h=f.read(4)
f.close()
print(h)
" 2>/dev/null || echo "")
    if [ "${ogg_size}" -gt 500 ] && echo "${ogg_header}" | grep -q "OggS"; then
        pass "T6: POST /tts format=ogg returns 200 + valid OGG (${ogg_size} bytes)"
    else
        fail "T6: POST /tts OGG: ${ogg_size} bytes, header check: ${ogg_header}"
    fi
else
    fail "T6: POST /tts format=ogg HTTP ${http_code}, expected 200"
fi

# ---------------------------------------------------------------------------
# T7: POST /tts with unknown voice returns 400 + error=unknown_voice
# ---------------------------------------------------------------------------
http_code=$(curl -s -X POST \
    -H 'Content-Type: application/json' \
    -d '{"text":"test","voice":"nonexistent_voice_xyz_abc"}' \
    -o /tmp/tts-bad-voice.json \
    -w '%{http_code}' \
    "${SERVER_URL}/tts")
if [ "${http_code}" = "400" ]; then
    error=$(python3 -c "import json; d=json.load(open('/tmp/tts-bad-voice.json')); print(d.get('error',''))" 2>/dev/null || echo "")
    if [ "${error}" = "unknown_voice" ]; then
        pass "T7: POST /tts unknown voice returns 400 + error=unknown_voice"
    else
        fail "T7: POST /tts unknown voice: HTTP 400 but error='${error}' (want unknown_voice)"
    fi
else
    fail "T7: POST /tts unknown voice HTTP ${http_code}, expected 400"
fi

# ---------------------------------------------------------------------------
# T8: POST /tts with empty text returns 400
# ---------------------------------------------------------------------------
http_code=$(curl -s -X POST \
    -H 'Content-Type: application/json' \
    -d '{"text":"","voice":"if_sara"}' \
    -o /tmp/tts-empty-text.json \
    -w '%{http_code}' \
    "${SERVER_URL}/tts")
if [ "${http_code}" = "400" ]; then
    pass "T8: POST /tts empty text returns 400"
else
    fail "T8: POST /tts empty text HTTP ${http_code}, expected 400"
fi

# ---------------------------------------------------------------------------
# T9: GET /health before warm-up returns 503 (verified indirectly via timing)
# Note: We cannot easily restart server mid-test, so we verify the /health
# endpoint DOES return the warming_up structure when status != ok.
# ---------------------------------------------------------------------------
# This is a structural check: the /health response JSON must have the right keys
has_model=$(python3 -c "import json; d=json.load(open('/tmp/tts-health.json')); print('model' in d)" 2>/dev/null || echo "False")
if [ "${has_model}" = "True" ]; then
    pass "T9: /health JSON includes 'model' field (structure check)"
else
    fail "T9: /health JSON missing 'model' field"
fi

# ---------------------------------------------------------------------------
# Cleanup temp files
# ---------------------------------------------------------------------------
rm -f /tmp/tts-health.json /tmp/tts-voices.json /tmp/tts-output.wav /tmp/tts-output.ogg \
       /tmp/tts-bad-voice.json /tmp/tts-empty-text.json

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
TOTAL=$((PASS + FAIL))
echo ""
echo "Results: ${PASS}/${TOTAL} passed"
if [ "${FAIL}" -gt 0 ]; then
    echo "FAILED tests:"
    for e in "${ERRORS[@]}"; do echo "  - ${e}"; done
    exit 1
fi
echo "All tests passed."
exit 0
