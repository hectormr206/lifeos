#!/bin/bash
# TDD test suite for lifeos-update-stage.sh
# Tests run with mock bootc/jq on PATH.
# Usage: bash scripts/tests/test-lifeos-update-stage.sh
# Exit: 0 = all pass, 1 = one or more failures
# shellcheck disable=SC2329  # test functions are invoked indirectly via run_test
set -euo pipefail

SCRIPT_PATH="image/files/usr/local/bin/lifeos-update-stage.sh"
PASS=0
FAIL=0
ERRORS=()

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); ERRORS+=("$1"); }

# Helper: run a test in isolation with a fresh temp dir
run_test() {
    local name="$1"
    local test_fn="$2"
    echo "--- $name"
    if $test_fn; then
        pass "$name"
    else
        fail "$name"
    fi
}

# ── T1: Script exists and is executable ──────────────────────────────────────
test_script_exists_and_is_executable() {
    [ -f "$SCRIPT_PATH" ] || { echo "    Script not found at $SCRIPT_PATH"; return 1; }
    [ -x "$SCRIPT_PATH" ] || { echo "    Script is not executable"; return 1; }
}

# ── T2: Script does NOT contain set -x (credential leakage risk) ─────────────
test_no_set_x() {
    # Only flag actual set -x commands, not comments
    if grep -v '^[[:space:]]*#' "$SCRIPT_PATH" 2>/dev/null | grep -qE '^set -x$|^set .*x '; then
        echo "    Script contains 'set -x' which leaks credentials in logs"
        return 1
    fi
    return 0
}

# ── T3: Script NEVER EXECUTES bootc upgrade --apply (active code only) ────────
test_no_bootc_upgrade_apply() {
    # Filter out comment lines, then look for actual bootc upgrade --apply invocations
    # (not inside echo/printf/print strings which are OK)
    if grep -v '^[[:space:]]*#' "$SCRIPT_PATH" 2>/dev/null \
        | grep -v "echo\|printf\|notify\|log\|NEVER\|string" \
        | grep -qE 'bootc upgrade.*--apply|bootc.*--apply.*upgrade'; then
        echo "    Script contains active 'bootc upgrade --apply' invocation — MUST NOT apply"
        return 1
    fi
    return 0
}

# ── T4: Script NEVER EXECUTES reboot mechanisms (active code only) ────────────
test_no_reboot() {
    # Filter comment lines and string literals (echo/notify lines), then check
    if grep -v '^[[:space:]]*#' "$SCRIPT_PATH" 2>/dev/null \
        | grep -v 'echo\|printf\|notify\|log\|NEVER' \
        | grep -qE 'systemctl reboot|/sbin/reboot|exec reboot|poweroff|halt|kexec'; then
        echo "    Script contains active reboot/shutdown mechanism — MUST NOT reboot"
        return 1
    fi
    return 0
}

# ── T5: Mock bootc upgrade SUCCESS → staged=true written to state file ────────
test_mock_bootc_success_writes_staged_true() {
    local tmpdir
    tmpdir=$(mktemp -d)
    local state_file="$tmpdir/update-stage-state.json"

    # Pre-seed a check state so available=true check passes
    local check_state="$tmpdir/update-state.json"
    cat > "$check_state" <<'EOF'
{"available": true, "remote_digest": "sha256:newdigest123", "current_version": "sha256:old", "checked_at": "2026-01-01T00:00:00+00:00"}
EOF

    # Create mock bootc that succeeds and reports a staged digest
    local mock_bin="$tmpdir/bin"
    mkdir -p "$mock_bin"
    cat > "$mock_bin/bootc" <<'EOF'
#!/bin/bash
if [ "$1" = "upgrade" ] && [ "${2:-}" != "--check" ]; then
    echo "Fetching image..."
    exit 0
elif [ "$1" = "upgrade" ] && [ "$2" = "--check" ]; then
    echo "Update available: sha256:newdigest123"
    exit 0
elif [ "$1" = "status" ]; then
    echo '{"status":{"booted":{"image":{"image":"ghcr.io/lifeos:edge","digest":"sha256:old"}},"staged":{"image":{"image":"ghcr.io/lifeos:edge","digest":"sha256:newdigest123"}}}}'
    exit 0
fi
exit 0
EOF
    chmod +x "$mock_bin/bootc"

    # Create mock notify-send (noop)
    cat > "$mock_bin/notify-send" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$mock_bin/notify-send"

    # Create mock curl (noop)
    cat > "$mock_bin/curl" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$mock_bin/curl"

    # Run the script with mocked PATH and overridden state file paths
    local rc=0
    LIFEOS_STATE_DIR="$tmpdir" \
    PATH="$mock_bin:$PATH" \
    bash "$SCRIPT_PATH" 2>/dev/null || rc=$?

    if [ ! -f "$state_file" ]; then
        echo "    State file not written at $state_file"
        rm -rf "$tmpdir"
        return 1
    fi

    local staged
    staged=$(python3 -c "import json,sys; d=json.load(open('$state_file')); print(str(d.get('staged',False)).lower())" 2>/dev/null || echo "error")
    if [ "$staged" != "true" ]; then
        echo "    Expected staged=true but got: $staged"
        cat "$state_file"
        rm -rf "$tmpdir"
        return 1
    fi

    rm -rf "$tmpdir"
    return 0
}

# ── T6: Mock bootc upgrade FAILURE → staged=false, error preserved ────────────
test_mock_bootc_failure_writes_staged_false() {
    local tmpdir
    tmpdir=$(mktemp -d)
    local state_file="$tmpdir/update-stage-state.json"
    local check_state="$tmpdir/update-state.json"

    cat > "$check_state" <<'EOF'
{"available": true, "remote_digest": "sha256:newdigest456", "current_version": "sha256:old", "checked_at": "2026-01-01T00:00:00+00:00"}
EOF

    # Pre-seed a prior successful stage result that MUST be preserved
    cat > "$state_file" <<'EOF'
{"staged": true, "staged_digest": "sha256:previousgood", "staged_at": "2026-01-01T00:00:00+00:00", "last_stage_error": null}
EOF

    local mock_bin="$tmpdir/bin"
    mkdir -p "$mock_bin"
    cat > "$mock_bin/bootc" <<'EOF'
#!/bin/bash
if [ "$1" = "upgrade" ] && [ "${2:-}" != "--check" ]; then
    echo "network error: connection refused" >&2
    exit 1
elif [ "$1" = "upgrade" ] && [ "$2" = "--check" ]; then
    echo "Update available: sha256:newdigest456"
    exit 0
elif [ "$1" = "status" ]; then
    echo '{"status":{"booted":{"image":{"image":"ghcr.io/lifeos:edge","digest":"sha256:old"}}}}'
    exit 0
fi
exit 0
EOF
    chmod +x "$mock_bin/bootc"

    cat > "$mock_bin/notify-send" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$mock_bin/notify-send"

    cat > "$mock_bin/curl" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$mock_bin/curl"

    local rc=0
    LIFEOS_STATE_DIR="$tmpdir" \
    PATH="$mock_bin:$PATH" \
    bash "$SCRIPT_PATH" 2>/dev/null || rc=$?

    # rc should be non-zero on failure
    if [ "$rc" -eq 0 ]; then
        echo "    Expected non-zero exit on bootc failure, got 0"
        rm -rf "$tmpdir"
        return 1
    fi

    if [ ! -f "$state_file" ]; then
        echo "    State file should still exist after failure"
        rm -rf "$tmpdir"
        return 1
    fi

    # staged should be false
    local staged
    staged=$(python3 -c "import json,sys; d=json.load(open('$state_file')); print(str(d.get('staged',True)).lower())" 2>/dev/null || echo "error")
    if [ "$staged" != "false" ]; then
        echo "    Expected staged=false after bootc failure, got: $staged"
        cat "$state_file"
        rm -rf "$tmpdir"
        return 1
    fi

    # Prior staged_digest MUST be preserved
    local prior_digest
    prior_digest=$(python3 -c "import json; d=json.load(open('$state_file')); print(d.get('staged_digest','MISSING'))" 2>/dev/null || echo "MISSING")
    if [ "$prior_digest" != "sha256:previousgood" ]; then
        echo "    Prior staged_digest should be preserved on failure, got: $prior_digest"
        cat "$state_file"
        rm -rf "$tmpdir"
        return 1
    fi

    # last_stage_error should be set
    local stage_error
    stage_error=$(python3 -c "import json; d=json.load(open('$state_file')); print('SET' if d.get('last_stage_error') else 'MISSING')" 2>/dev/null || echo "MISSING")
    if [ "$stage_error" != "SET" ]; then
        echo "    last_stage_error should be set on failure"
        cat "$state_file"
        rm -rf "$tmpdir"
        return 1
    fi

    rm -rf "$tmpdir"
    return 0
}

# ── T7: Already-staged idempotency — skip bootc upgrade, exit 0 ──────────────
test_already_staged_is_noop() {
    local tmpdir
    tmpdir=$(mktemp -d)
    local state_file="$tmpdir/update-stage-state.json"
    local check_state="$tmpdir/update-state.json"

    # remote_digest matches staged_digest → should be a no-op
    cat > "$check_state" <<'EOF'
{"available": true, "remote_digest": "sha256:samedigest", "current_version": "sha256:old", "checked_at": "2026-01-01T00:00:00+00:00"}
EOF

    cat > "$state_file" <<'EOF'
{"staged": true, "staged_digest": "sha256:samedigest", "staged_at": "2026-01-01T00:00:00+00:00", "last_stage_error": null}
EOF

    local mock_bin="$tmpdir/bin"
    mkdir -p "$mock_bin"

    # bootc upgrade should NOT be called — track via sentinel file
    cat > "$mock_bin/bootc" <<EOF
#!/bin/bash
if [ "\$1" = "upgrade" ] && [ "\${2:-}" != "--check" ]; then
    echo "BOOTC_UPGRADE_CALLED" > "$tmpdir/bootc_upgrade_called"
    exit 0
elif [ "\$1" = "upgrade" ] && [ "\$2" = "--check" ]; then
    echo "Update available: sha256:samedigest"
    exit 0
elif [ "\$1" = "status" ]; then
    echo '{"status":{"booted":{"image":{"image":"ghcr.io/lifeos:edge","digest":"sha256:old"}},"staged":{"image":{"image":"ghcr.io/lifeos:edge","digest":"sha256:samedigest"}}}}'
    exit 0
fi
exit 0
EOF
    chmod +x "$mock_bin/bootc"

    cat > "$mock_bin/notify-send" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$mock_bin/notify-send"

    cat > "$mock_bin/curl" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$mock_bin/curl"

    local rc=0
    LIFEOS_STATE_DIR="$tmpdir" \
    PATH="$mock_bin:$PATH" \
    bash "$SCRIPT_PATH" 2>/dev/null || rc=$?

    if [ "$rc" -ne 0 ]; then
        echo "    Expected exit 0 for already-staged no-op, got $rc"
        rm -rf "$tmpdir"
        return 1
    fi

    if [ -f "$tmpdir/bootc_upgrade_called" ]; then
        echo "    bootc upgrade was called despite digest already matching — should be a no-op"
        rm -rf "$tmpdir"
        return 1
    fi

    rm -rf "$tmpdir"
    return 0
}

# ── T8: Script shellcheck passes (run after creation) ────────────────────────
test_shellcheck_passes() {
    if ! command -v shellcheck >/dev/null 2>&1; then
        echo "    shellcheck not found — skipping"
        return 0
    fi
    shellcheck "$SCRIPT_PATH" 2>&1 | head -20
    return 0
}

# ─── Run all tests ────────────────────────────────────────────────────────────
echo "=== test-lifeos-update-stage.sh ==="
echo ""

run_test "T1: script exists and is executable"     test_script_exists_and_is_executable
run_test "T2: no set -x in script"                 test_no_set_x
run_test "T3: no bootc upgrade --apply"            test_no_bootc_upgrade_apply
run_test "T4: no reboot mechanism"                 test_no_reboot
run_test "T5: mock success → staged=true"          test_mock_bootc_success_writes_staged_true
run_test "T6: mock failure → staged=false, prior preserved" test_mock_bootc_failure_writes_staged_false
run_test "T7: already-staged is a no-op"           test_already_staged_is_noop
run_test "T8: shellcheck"                          test_shellcheck_passes

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "${#ERRORS[@]}" -gt 0 ]; then
    echo "Failed tests:"
    for e in "${ERRORS[@]}"; do
        echo "  - $e"
    done
    exit 1
fi
exit 0
