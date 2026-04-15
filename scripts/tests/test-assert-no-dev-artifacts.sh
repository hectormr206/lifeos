#!/usr/bin/env bash
# scripts/tests/test-assert-no-dev-artifacts.sh
# TDD test suite for scripts/assert-no-dev-artifacts.sh
# Run with: bash scripts/tests/test-assert-no-dev-artifacts.sh
# Exit 0 = all tests passed, non-zero = one or more failures.

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/assert-no-dev-artifacts.sh"
PASS=0
FAIL=0
ERRORS=()

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); ERRORS+=("$1"); }

run_script() {
    # Run script, capture exit code safely
    set +e
    bash "${SCRIPT}" "$@" 2>&1
    _rc=$?
    set -e
    return "${_rc}"
}

get_rc() {
    set +e
    bash "${SCRIPT}" "$@" >/dev/null 2>&1
    _rc=$?
    set -e
    echo "${_rc}"
}

# --- Test 1: No args exits 2 (usage error) ---
rc=$(get_rc)
if [ "${rc}" -eq 2 ]; then
    pass "T1: no-args exits 2"
else
    fail "T1: expected exit 2 on no args, got ${rc}"
fi

# --- Test 2: Clean rootfs exits 0 ---
CLEAN_ROOT=$(mktemp -d)
rc=$(get_rc "${CLEAN_ROOT}")
if [ "${rc}" -eq 0 ]; then
    pass "T2: clean rootfs exits 0"
else
    fail "T2: clean rootfs expected exit 0, got ${rc}"
fi
rm -rf "${CLEAN_ROOT}"

# --- Test 3: Rootfs with one forbidden file exits 1 ---
DIRTY_ROOT=$(mktemp -d)
mkdir -p "${DIRTY_ROOT}/etc/sudoers.d"
touch "${DIRTY_ROOT}/etc/sudoers.d/lifeos-dev"
rc=$(get_rc "${DIRTY_ROOT}")
if [ "${rc}" -eq 1 ]; then
    pass "T3: dirty rootfs (lifeos-dev) exits 1"
else
    fail "T3: dirty rootfs expected exit 1, got ${rc}"
fi

# --- Test 4: Forbidden path name appears in output ---
set +e
output=$(bash "${SCRIPT}" "${DIRTY_ROOT}" 2>&1)
set -e
if echo "${output}" | grep -q "lifeos-dev"; then
    pass "T4: offending path appears in output"
else
    fail "T4: offending path not in output. Got: ${output}"
fi
rm -rf "${DIRTY_ROOT}"

# --- Test 5: Second forbidden path (10-dev-mode.conf) exits 1 ---
DIRTY2=$(mktemp -d)
mkdir -p "${DIRTY2}/etc/systemd/user/lifeosd.service.d"
touch "${DIRTY2}/etc/systemd/user/lifeosd.service.d/10-dev-mode.conf"
rc=$(get_rc "${DIRTY2}")
if [ "${rc}" -eq 1 ]; then
    pass "T5: 10-dev-mode.conf forbidden path exits 1"
else
    fail "T5: expected exit 1 for 10-dev-mode.conf, got ${rc}"
fi
rm -rf "${DIRTY2}"

# --- Test 6: All six forbidden paths detected, exits 1 ---
ALL_DIRTY=$(mktemp -d)
mkdir -p "${ALL_DIRTY}/etc/sudoers.d"
mkdir -p "${ALL_DIRTY}/etc/systemd/user/lifeosd.service.d"
mkdir -p "${ALL_DIRTY}/etc/systemd/system/lifeos-sentinel.service.d"
touch "${ALL_DIRTY}/etc/sudoers.d/lifeos-dev"
touch "${ALL_DIRTY}/etc/sudoers.d/lifeos-dev-host"
touch "${ALL_DIRTY}/etc/systemd/user/lifeosd.service.d/10-dev-mode.conf"
touch "${ALL_DIRTY}/etc/systemd/user/lifeosd.service.d/10-dev-rust-log.conf"
touch "${ALL_DIRTY}/etc/systemd/system/lifeos-sentinel.service.d/10-dev-mode-override.conf"
touch "${ALL_DIRTY}/etc/systemd/system/lifeos-sentinel.service.d/10-dev-sentinel-path.conf"
rc=$(get_rc "${ALL_DIRTY}")
if [ "${rc}" -eq 1 ]; then
    pass "T6: all six forbidden paths present → exit 1"
else
    fail "T6: all six forbidden paths expected exit 1, got ${rc}"
fi

# --- Test 7: All six offending paths appear in output ---
set +e
output=$(bash "${SCRIPT}" "${ALL_DIRTY}" 2>&1)
set -e
found=0
for path in lifeos-dev lifeos-dev-host 10-dev-mode.conf 10-dev-rust-log.conf 10-dev-mode-override.conf 10-dev-sentinel-path.conf; do
    if echo "${output}" | grep -q "${path}"; then
        found=$((found + 1))
    fi
done
if [ "${found}" -ge 6 ]; then
    pass "T7: all six offending paths appear in output"
else
    fail "T7: only ${found}/6 offending paths in output. Got: ${output}"
fi
rm -rf "${ALL_DIRTY}"

# --- Test 8: Success message on clean rootfs ---
CLEAN2=$(mktemp -d)
set +e
output=$(bash "${SCRIPT}" "${CLEAN2}" 2>&1)
rc=$?
set -e
if [ "${rc}" -eq 0 ] && echo "${output}" | grep -q "No dev artifacts found"; then
    pass "T8: clean rootfs prints 'No dev artifacts found.'"
else
    fail "T8: clean rootfs rc=${rc}, output: ${output}"
fi
rm -rf "${CLEAN2}"

# --- Summary ---
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
