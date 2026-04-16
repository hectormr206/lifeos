#!/usr/bin/env bash
# scripts/tests/test-assert-no-piper.sh
# TDD test suite for scripts/assert-no-piper.sh
# Run with: bash scripts/tests/test-assert-no-piper.sh
# Exit 0 = all tests passed, non-zero = one or more failures.

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/assert-no-piper.sh"
PASS=0
FAIL=0
ERRORS=()

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); ERRORS+=("$1"); }

get_rc() {
    set +e
    bash "${SCRIPT}" "$@" >/dev/null 2>&1
    _rc=$?
    set -e
    echo "${_rc}"
}

# ─────────────────────────────────────────────────────────────────────────────
# T1: No-args exits 2 (usage error)
# ─────────────────────────────────────────────────────────────────────────────
rc=$(get_rc)
if [ "${rc}" -eq 2 ]; then
    pass "T1: no-args exits 2 (usage error)"
else
    fail "T1: expected exit 2 on no args, got ${rc}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# T2: Clean directory (no piper) exits 0
# ─────────────────────────────────────────────────────────────────────────────
CLEAN_DIR=$(mktemp -d)
rc=$(get_rc "${CLEAN_DIR}")
if [ "${rc}" -eq 0 ]; then
    pass "T2: clean directory exits 0"
else
    fail "T2: clean directory expected exit 0, got ${rc}"
fi
rm -rf "${CLEAN_DIR}"

# ─────────────────────────────────────────────────────────────────────────────
# T3: Forbidden path /usr/local/bin/lifeos-piper detected, exits 1
# ─────────────────────────────────────────────────────────────────────────────
DIRTY_BIN=$(mktemp -d)
mkdir -p "${DIRTY_BIN}/usr/local/bin"
touch "${DIRTY_BIN}/usr/local/bin/lifeos-piper"
rc=$(get_rc "${DIRTY_BIN}")
if [ "${rc}" -eq 1 ]; then
    pass "T3: forbidden path lifeos-piper exits 1"
else
    fail "T3: expected exit 1 for lifeos-piper path, got ${rc}"
fi
rm -rf "${DIRTY_BIN}"

# ─────────────────────────────────────────────────────────────────────────────
# T4: Forbidden path /usr/share/lifeos/models/piper/ detected, exits 1
# ─────────────────────────────────────────────────────────────────────────────
DIRTY_MODELS=$(mktemp -d)
mkdir -p "${DIRTY_MODELS}/usr/share/lifeos/models/piper"
touch "${DIRTY_MODELS}/usr/share/lifeos/models/piper/es_MX-claude.onnx"
rc=$(get_rc "${DIRTY_MODELS}")
if [ "${rc}" -eq 1 ]; then
    pass "T4: forbidden path piper models dir exits 1"
else
    fail "T4: expected exit 1 for piper models dir, got ${rc}"
fi
rm -rf "${DIRTY_MODELS}"

# ─────────────────────────────────────────────────────────────────────────────
# T5: Forbidden path /opt/lifeos/piper-tts/ detected, exits 1
# ─────────────────────────────────────────────────────────────────────────────
DIRTY_OPT=$(mktemp -d)
mkdir -p "${DIRTY_OPT}/opt/lifeos/piper-tts"
touch "${DIRTY_OPT}/opt/lifeos/piper-tts/piper"
rc=$(get_rc "${DIRTY_OPT}")
if [ "${rc}" -eq 1 ]; then
    pass "T5: forbidden path /opt/lifeos/piper-tts exits 1"
else
    fail "T5: expected exit 1 for /opt/lifeos/piper-tts, got ${rc}"
fi
rm -rf "${DIRTY_OPT}"

# ─────────────────────────────────────────────────────────────────────────────
# T6: Containerfile with LIFEOS_TTS_BIN string detected, exits 1
# ─────────────────────────────────────────────────────────────────────────────
TMP_CF=$(mktemp --suffix=.Containerfile)
printf 'FROM fedora:41\nENV LIFEOS_TTS_BIN=/usr/local/bin/lifeos-piper\nRUN echo ok\n' > "${TMP_CF}"
rc=$(get_rc "${TMP_CF}")
if [ "${rc}" -eq 1 ]; then
    pass "T6: Containerfile with LIFEOS_TTS_BIN exits 1"
else
    fail "T6: expected exit 1 for LIFEOS_TTS_BIN in Containerfile, got ${rc}"
fi
rm -f "${TMP_CF}"

# ─────────────────────────────────────────────────────────────────────────────
# T7: Containerfile with piper-voice-builder string detected, exits 1
# ─────────────────────────────────────────────────────────────────────────────
TMP_CF2=$(mktemp --suffix=.Containerfile)
printf 'FROM fedora:41 AS piper-voice-builder\nRUN echo building piper\n' > "${TMP_CF2}"
rc=$(get_rc "${TMP_CF2}")
if [ "${rc}" -eq 1 ]; then
    pass "T7: Containerfile with piper-voice-builder exits 1"
else
    fail "T7: expected exit 1 for piper-voice-builder in Containerfile, got ${rc}"
fi
rm -f "${TMP_CF2}"

# ─────────────────────────────────────────────────────────────────────────────
# T8: Clean Containerfile exits 0
# ─────────────────────────────────────────────────────────────────────────────
TMP_CF3=$(mktemp --suffix=.Containerfile)
printf 'FROM fedora:41\nRUN dnf install -y ffmpeg\nRUN echo kokoro\n' > "${TMP_CF3}"
rc=$(get_rc "${TMP_CF3}")
if [ "${rc}" -eq 0 ]; then
    pass "T8: clean Containerfile exits 0"
else
    fail "T8: expected exit 0 for clean Containerfile, got ${rc}"
fi
rm -f "${TMP_CF3}"

# ─────────────────────────────────────────────────────────────────────────────
# T9: .service file with lifeos-piper string detected, exits 1
# ─────────────────────────────────────────────────────────────────────────────
TMP_SVC_DIR=$(mktemp -d)
mkdir -p "${TMP_SVC_DIR}/etc/systemd/system"
printf '[Unit]\nDescription=test\n[Service]\nExecStart=/usr/local/bin/lifeos-piper --model /usr/share/lifeos/models/piper/es_MX-claude.onnx\n' \
    > "${TMP_SVC_DIR}/etc/systemd/system/lifeos-piper.service"
rc=$(get_rc "${TMP_SVC_DIR}")
if [ "${rc}" -eq 1 ]; then
    pass "T9: .service file with lifeos-piper exits 1"
else
    fail "T9: expected exit 1 for lifeos-piper in .service, got ${rc}"
fi
rm -rf "${TMP_SVC_DIR}"

# ─────────────────────────────────────────────────────────────────────────────
# T10: .env file with LIFEOS_TTS_MODEL string detected, exits 1
# ─────────────────────────────────────────────────────────────────────────────
TMP_ENV_DIR=$(mktemp -d)
mkdir -p "${TMP_ENV_DIR}/etc/lifeos"
printf 'LIFEOS_TTS_MODEL=/usr/share/lifeos/models/piper/es_MX-claude.onnx\n' \
    > "${TMP_ENV_DIR}/etc/lifeos/lifeosd.env"
rc=$(get_rc "${TMP_ENV_DIR}")
if [ "${rc}" -eq 1 ]; then
    pass "T10: .env file with LIFEOS_TTS_MODEL exits 1"
else
    fail "T10: expected exit 1 for LIFEOS_TTS_MODEL in .env, got ${rc}"
fi
rm -rf "${TMP_ENV_DIR}"

# ─────────────────────────────────────────────────────────────────────────────
# T11: Offending file path/line appears in output
# ─────────────────────────────────────────────────────────────────────────────
TMP_CF4=$(mktemp --suffix=.Containerfile)
printf 'FROM fedora:41\nENV LIFEOS_TTS_BIN=/usr/local/bin/lifeos-piper\n' > "${TMP_CF4}"
set +e
output=$(bash "${SCRIPT}" "${TMP_CF4}" 2>&1)
set -e
if echo "${output}" | grep -q "LIFEOS_TTS_BIN\|lifeos-piper"; then
    pass "T11: offending pattern appears in output"
else
    fail "T11: offending pattern not in output. Got: ${output}"
fi
rm -f "${TMP_CF4}"

# ─────────────────────────────────────────────────────────────────────────────
# T12: Success message on clean input
# ─────────────────────────────────────────────────────────────────────────────
CLEAN2=$(mktemp -d)
set +e
output=$(bash "${SCRIPT}" "${CLEAN2}" 2>&1)
rc=$?
set -e
if [ "${rc}" -eq 0 ] && echo "${output}" | grep -qi "pass\|no piper"; then
    pass "T12: clean dir prints success message"
else
    fail "T12: clean dir rc=${rc}, output: ${output}"
fi
rm -rf "${CLEAN2}"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
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
