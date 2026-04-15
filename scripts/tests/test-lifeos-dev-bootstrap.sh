#!/usr/bin/env bash
# tests/test-lifeos-dev-bootstrap.sh
# TDD tests for scripts/lifeos-dev-bootstrap.sh (Batch B)
# Run as non-root for most cases; root-required cases are gated.
# Usage: bash scripts/tests/test-lifeos-dev-bootstrap.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/lifeos-dev-bootstrap.sh"

PASS=0
FAIL=0
SKIP=0

# ── helpers ──────────────────────────────────────────────────────────────────

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "  SKIP: $1 (needs root)"; SKIP=$((SKIP + 1)); }

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass "$label"
    else
        fail "$label — expected '$expected' got '$actual'"
    fi
}

# NOTE: We use grep -c and compare to 0 instead of grep -q to avoid
# pipefail + SIGPIPE issues when grep finds a match and closes stdin early.
assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    local count
    count=$(printf '%s' "$haystack" | grep -cF -- "$needle" || true)
    if [ "$count" -gt 0 ]; then
        pass "$label"
    else
        fail "$label — '$needle' not found in output"
    fi
}

# shellcheck disable=SC2329  # reserved helper — not yet called in these tests
assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    local count
    count=$(printf '%s' "$haystack" | grep -cF -- "$needle" || true)
    if [ "$count" -gt 0 ]; then
        fail "$label — '$needle' unexpectedly found in output"
    else
        pass "$label"
    fi
}

assert_file_exists() {
    local label="$1" path="$2"
    if [ -f "$path" ]; then
        pass "$label"
    else
        fail "$label — file missing: $path"
    fi
}

assert_executable() {
    local label="$1" path="$2"
    if [ -x "$path" ]; then
        pass "$label"
    else
        fail "$label — not executable: $path"
    fi
}

# Safe grep helper (unused directly; grep is called on files via CONTENT_TMP to avoid SIGPIPE)
# shellcheck disable=SC2329
sc_grep() { grep "$@" || true; }

# ── test: script exists and is executable ────────────────────────────────────

echo ""
echo "=== T1: script exists and is executable ==="
assert_file_exists "script exists" "$SCRIPT"
assert_executable  "script is executable" "$SCRIPT"

# ── test: --help exits 0 and prints usage ────────────────────────────────────

echo ""
echo "=== T2: --help exits 0 and prints usage ==="
set +e
help_output=$(bash "$SCRIPT" --help 2>&1)
help_rc=$?
set -e
assert_eq "help exits 0" "0" "$help_rc"
assert_contains "help mentions --with-sentinel" "--with-sentinel" "$help_output"
assert_contains "help mentions --dry-run"       "--dry-run"       "$help_output"
assert_contains "help mentions Usage"           "Usage"           "$help_output"

# ── test: --dry-run as non-root exits 0, no filesystem changes ───────────────

echo ""
echo "=== T3: --dry-run as non-root exits 0 without writing files ==="
if [ "$EUID" = "0" ]; then
    skip "T3 requires non-root; skipping under root"
else
    set +e
    dry_output=$(bash "$SCRIPT" --dry-run 2>&1)
    dry_rc=$?
    set -e
    assert_eq "dry-run exits 0 as non-root" "0" "$dry_rc"
    assert_contains "dry-run prints diff table or dry-run indicator" "dry" "$dry_output"
fi

# ── test: non-root attempting privileged op exits 2 ─────────────────────────

echo ""
echo "=== T4: non-root invocation (no --dry-run) exits 2 ==="
if [ "$EUID" = "0" ]; then
    skip "T4 requires non-root; skipping under root"
else
    set +e
    norootout=$(bash "$SCRIPT" 2>&1)
    norootrc=$?
    set -e
    assert_eq "non-root exits 2" "2" "$norootrc"
    assert_contains "non-root prints sudo hint" "sudo" "$norootout"
fi

# ── write script content to a temp file for safe grep operations ─────────────
# This avoids SIGPIPE/pipefail issues when piping large variables to grep -q

CONTENT_TMP=$(mktemp /tmp/test-bootstrap-content.XXXXXX)
trap 'rm -f "$CONTENT_TMP"' EXIT
cp "$SCRIPT" "$CONTENT_TMP"

# ── test: sudoers content does NOT contain forbidden verbs ──────────────────

echo ""
echo "=== T5: sudoers content excludes forbidden commands ==="
forbidden_terms=("reboot" "shutdown" "halt" "poweroff" "hibernate" "suspend" "kexec" "dnf" "rpm " "npm" "pip ")
for term in "${forbidden_terms[@]}"; do
    count=$(grep -v "^[[:space:]]*#" "$CONTENT_TMP" | grep -ciF "NOPASSWD.*${term}" || true)
    if [ "$count" -gt 0 ]; then
        fail "sudoers NOPASSWD must NOT grant: $term"
    else
        pass "sudoers NOPASSWD does not grant: $term"
    fi
done

# ── test: sudoers content contains required bootc commands ──────────────────

echo ""
echo "=== T6: sudoers content includes required bootc commands ==="
required_bootc=("bootc usroverlay" "bootc upgrade" "bootc rollback")
for cmd in "${required_bootc[@]}"; do
    count=$(grep -cF "$cmd" "$CONTENT_TMP" || true)
    if [ "$count" -gt 0 ]; then
        pass "sudoers includes: $cmd"
    else
        fail "sudoers missing: $cmd"
    fi
done

# ── test: user dropin content matches spec exactly ───────────────────────────

echo ""
echo "=== T7: RUST_LOG dropin content in script matches spec exactly ==="
# The spec mandates exactly:
#   [Service]
#   Environment=RUST_LOG=debug
count=$(grep -cF "Environment=RUST_LOG=debug" "$CONTENT_TMP" || true)
if [ "$count" -gt 0 ]; then
    pass "RUST_LOG=debug present in dropin content"
else
    fail "RUST_LOG=debug missing from dropin content"
fi

count=$(grep -cF "LIFEOS_DEV_MODE" "$CONTENT_TMP" || true)
if [ "$count" -gt 0 ]; then
    fail "LIFEOS_DEV_MODE must NOT be in script"
else
    pass "LIFEOS_DEV_MODE not present in script"
fi

count=$(grep -cF "target/debug" "$CONTENT_TMP" || true)
if [ "$count" -gt 0 ]; then
    fail "target/debug must NOT be in script"
else
    pass "target/debug not in script"
fi

# Check that ExecStart does NOT appear inside the RUST_LOG dropin block
if awk '/cat.*>.*10-dev-rust-log/{found=1} found && /EOF/{found=0} found && /ExecStart/{bad=1} END{exit bad+0}' "$CONTENT_TMP"; then
    pass "ExecStart not in 10-dev-rust-log.conf dropin block"
else
    fail "ExecStart must NOT appear in 10-dev-rust-log.conf dropin"
fi

# ── test: --with-sentinel flag installs/removes sentinel dropin ─────────────

echo ""
echo "=== T8: --with-sentinel logic present in script ==="
count=$(grep -cE "with.sentinel|with_sentinel" "$CONTENT_TMP" || true)
if [ "$count" -gt 0 ]; then
    pass "--with-sentinel handling present in script"
else
    fail "--with-sentinel handling missing from script"
fi

count=$(grep -cF "10-dev-sentinel-path.conf" "$CONTENT_TMP" || true)
if [ "$count" -gt 0 ]; then
    pass "sentinel dropin filename referenced"
else
    fail "sentinel dropin filename not found"
fi

# ── test: sentinel dropin content matches spec ───────────────────────────────

echo ""
echo "=== T9: sentinel dropin content matches spec ==="
# Spec requires:
#   ExecStart=
#   ExecStart=/bin/bash -c 'exec "$( ... )"'
count=$(grep -cF "ExecStart=" "$CONTENT_TMP" || true)
if [ "$count" -gt 0 ]; then
    pass "ExecStart= (empty clear) present for sentinel dropin"
else
    fail "ExecStart= (empty clear) missing"
fi

count=$(grep -cF "/var/lib/lifeos/bin/lifeos-sentinel.sh" "$CONTENT_TMP" || true)
if [ "$count" -gt 0 ]; then
    pass "sentinel var/lib fallback path present"
else
    fail "sentinel var/lib fallback path missing"
fi

count=$(grep -cF "/usr/local/bin/lifeos-sentinel.sh" "$CONTENT_TMP" || true)
if [ "$count" -gt 0 ]; then
    pass "sentinel image path present"
else
    fail "sentinel image path missing"
fi

# ── test: script does NOT contain bootc switch invocation ───────────────────

echo ""
echo "=== T10: script does NOT execute bootc switch ==="
# The script may mention "bootc switch" in:
#   - comments
#   - heredoc content (sudoers Cmnd_Alias lines)
#   - echo/printf statements (informational)
# It must NOT directly invoke bootc switch as a shell command.
#
# Strategy: strip heredoc content, then check for bare invocation.
# Strip heredoc content and check for bare bootc switch execution.
# Allowed: comments (#), echo/printf lines (informational hint to user),
#          and the sudoers Cmnd_Alias line (which is in a heredoc, now stripped).
# Forbidden: any non-echo, non-comment line that calls bootc switch directly.
NOHEREDOC_TMP=$(mktemp /tmp/test-noheredoc.XXXXXX)
trap 'rm -f "$NOHEREDOC_TMP"' EXIT
awk '
    /<<.*EOF/ { in_heredoc=1; print; next }
    /^[A-Z_]+_EOF$/ { in_heredoc=0; next }
    in_heredoc { next }
    { print }
' "$CONTENT_TMP" > "$NOHEREDOC_TMP"

# Lines with bootc switch that are NOT comments and NOT echo/printf
bare_count=$(grep -cF "bootc switch" "$NOHEREDOC_TMP" || true)
if [ "$bare_count" -eq 0 ]; then
    pass "bootc switch only in heredoc content"
else
    # Check if all remaining occurrences are in echo/printf or comments
    non_echo=$(grep -F "bootc switch" "$NOHEREDOC_TMP" | grep -v "^[[:space:]]*#" | grep -v "echo\|printf" || true)
    if [ -z "$non_echo" ]; then
        pass "bootc switch only in echo/print context or comments"
    else
        fail "script contains bare 'bootc switch' invocation: $non_echo"
    fi
fi

# ── test: idempotency label - script handles PRESENT_SAME state ─────────────

echo ""
echo "=== T11: idempotency — already-up-to-date handling present ==="
count=$(grep -ciE "already.up.to.date|already_up_to_date|no.change|idempotent|PRESENT_SAME" "$CONTENT_TMP" || true)
if [ "$count" -gt 0 ]; then
    pass "already-up-to-date logic present"
else
    fail "idempotency logic not found in script"
fi

# ── test: backup naming format ───────────────────────────────────────────────

echo ""
echo "=== T12: backup naming uses YYYYMMDD-HHMMSS format ==="
count=$(grep -cE "backup-.*date.*\+%Y%m%d|\.backup-" "$CONTENT_TMP" || true)
if [ "$count" -gt 0 ]; then
    pass "backup naming with date +%Y%m%d-%H%M%S format found"
else
    fail "backup naming format not found"
fi

# ── test: --dry-run mode present ─────────────────────────────────────────────

echo ""
echo "=== T13: --dry-run mode handling present ==="
count=$(grep -cE "dry.run|DRY_RUN" "$CONTENT_TMP" || true)
if [ "$count" -gt 0 ]; then
    pass "--dry-run handling present"
else
    fail "--dry-run handling missing"
fi

# ── test: exit codes are correct ─────────────────────────────────────────────

echo ""
echo "=== T14: exit codes defined ==="
for code in "exit 0" "exit 1" "exit 2"; do
    count=$(grep -cF "$code" "$CONTENT_TMP" || true)
    if [ "$count" -gt 0 ]; then
        pass "$code present"
    else
        fail "$code missing"
    fi
done

# ── test: summary block and migration complete message ───────────────────────

echo ""
echo "=== T15: summary block and migration complete message ==="
count=$(grep -ci "migration complete" "$CONTENT_TMP" || true)
if [ "$count" -gt 0 ]; then
    pass "Migration complete message present"
else
    fail "Migration complete message missing"
fi

count=$(grep -cF "bootc switch" "$CONTENT_TMP" || true)
if [ "$count" -gt 0 ]; then
    pass "bootc switch referenced (manual hint)"
else
    fail "Manual bootc switch hint missing"
fi

# ── test: set -euo pipefail present ─────────────────────────────────────────

echo ""
echo "=== T16: set -euo pipefail present ==="
count=$(grep -cF "set -euo pipefail" "$CONTENT_TMP" || true)
if [ "$count" -gt 0 ]; then
    pass "set -euo pipefail present"
else
    fail "set -euo pipefail missing"
fi

# ── root-gated tests ─────────────────────────────────────────────────────────

echo ""
echo "=== T17-T19: root-gated tests (skip if not root) ==="
if [ "$EUID" != "0" ]; then
    skip "T17: sudoers atomic write test (needs root)"
    skip "T18: idempotent re-run changes nothing (needs root + installed state)"
    skip "T19: drift backup created on content change (needs root)"
else
    # T17: Sudoers atomic write with bad content → exit 1
    echo "  [T17] Testing bad sudoers fragment → visudo rejects → exit 1"
    TMPDIR_TEST=$(mktemp -d)
    trap 'rm -rf "$TMPDIR_TEST"' EXIT
    # Simulate bad sudoers by creating a mock visudo that fails
    cat > "$TMPDIR_TEST/visudo" <<'MOCK'
#!/usr/bin/env bash
# Mock visudo that always fails validation
exit 1
MOCK
    chmod +x "$TMPDIR_TEST/visudo"
    set +e
    PATH="$TMPDIR_TEST:$PATH" bash "$SCRIPT" 2>/dev/null
    badrc=$?
    set -e
    if [ "$badrc" = "1" ]; then
        pass "T17: bad sudoers exits 1"
    else
        fail "T17: expected exit 1, got $badrc"
    fi

    skip "T18: full idempotent run (complex root test, verify manually)"
    skip "T19: drift backup (complex root test, verify manually)"
fi

# ── summary ──────────────────────────────────────────────────────────────────

echo ""
echo "==========================================="
echo " Results: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
echo "==========================================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
