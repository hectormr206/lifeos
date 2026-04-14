#!/bin/bash
# LifeOS — Local CI runner
#
# Thin wrapper sobre los targets del Makefile + checks extras
# (truth-alignment, shellcheck, hadolint, Rust version).
#
# Replica los workflows criticos de GitHub Actions en la laptop.
# Ejecutar ANTES de cada push para detectar errores localmente.
#
# Uso:
#   ./scripts/local-ci.sh          # Default: make ci + truth-alignment + shellcheck
#   ./scripts/local-ci.sh quick    # Solo fmt-check + lint (30s)
#   ./scripts/local-ci.sh full     # Default + hadolint + release build
#
# Exit code 0 = safe to push, non-zero = fix before push.
#
# Diseno:
#   - Cada step escribe stdout+stderr a un archivo temporal
#   - Si el step falla, se imprime el archivo temporal completo (no se
#     oculta nada — el proposito es saber QUE fallo)
#   - Si el step pasa, no se imprime la salida (ruido minimo)
#   - Los temporales se limpian al salir

set -uo pipefail

# ── Setup ────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

MODE="${1:-default}"
TMPDIR_CI="$(mktemp -d -t lifeos-ci-XXXXXX)"
trap 'rm -rf "$TMPDIR_CI"' EXIT

# ── TTY / Color detection ────────────────────────────────────────────
if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "${TERM}" != "dumb" ]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[1;33m'
    CYAN=$'\033[0;36m'
    BOLD=$'\033[1m'
    DIM=$'\033[2m'
    NC=$'\033[0m'
else
    RED="" GREEN="" YELLOW="" CYAN="" BOLD="" DIM="" NC=""
fi

# ── State ────────────────────────────────────────────────────────────
FAILED=0
PASSED=0
SKIPPED=0
RESULTS=()
FAILED_LOGS=()

# ── Helpers ──────────────────────────────────────────────────────────
step_header() {
    local name="$1"
    printf "\n${CYAN}${BOLD}▶${NC} ${BOLD}%s${NC}\n" "$name"
}

pass() {
    printf "  ${GREEN}✓ PASS${NC}\n"
    PASSED=$((PASSED + 1))
    RESULTS+=("${GREEN}✓${NC} $1")
}

fail() {
    local name="$1"
    local logfile="$2"
    printf "  ${RED}✗ FAIL${NC}\n"
    FAILED=$((FAILED + 1))
    RESULTS+=("${RED}✗${NC} $name")
    FAILED_LOGS+=("$name|$logfile")
}

skip() {
    local name="$1"
    local reason="$2"
    printf "  ${YELLOW}⊘ SKIP${NC} ${DIM}(%s)${NC}\n" "$reason"
    SKIPPED=$((SKIPPED + 1))
    RESULTS+=("${YELLOW}⊘${NC} $name ${DIM}($reason)${NC}")
}

# Run a command, capture output, pass/fail based on exit code.
# $1 = step name
# $2..N = command to run
run_step() {
    local name="$1"
    shift
    local logfile
    logfile="$TMPDIR_CI/$(echo "$name" | tr ' /' '__').log"
    step_header "$name"
    if "$@" > "$logfile" 2>&1; then
        pass "$name"
    else
        fail "$name" "$logfile"
    fi
}

# ── Banner ───────────────────────────────────────────────────────────
printf "\n${BOLD}${CYAN}LifeOS Local CI${NC} — pre-flight validation\n"
printf "${DIM}Mode: %s  |  Project: %s${NC}\n" "$MODE" "$PROJECT_ROOT"
printf "${DIM}Started: %s${NC}\n" "$(date '+%Y-%m-%d %H:%M:%S')"

START_TIME=$(date +%s)

# ── Preflight: Rust version check (soft) ─────────────────────────────
step_header "Rust toolchain check"
if [ -f "rust-toolchain.toml" ]; then
    PINNED=$(grep -E '^\s*channel' rust-toolchain.toml | sed -E 's/.*"([^"]+)".*/\1/')
    CURRENT=$(rustc --version 2>/dev/null | awk '{print $2}' || echo "none")
    if [ "$PINNED" = "$CURRENT" ]; then
        pass "Rust $CURRENT matches pinned ($PINNED)"
    else
        printf "  ${YELLOW}⚠ WARN${NC}  local=%s, pinned=%s ${DIM}(rustup should auto-switch)${NC}\n" "$CURRENT" "$PINNED"
        RESULTS+=("${YELLOW}⚠${NC} Rust version mismatch (local=$CURRENT, pinned=$PINNED)")
    fi
else
    skip "Rust version check" "no rust-toolchain.toml"
fi

# ── QUICK MODE ───────────────────────────────────────────────────────
if [ "$MODE" = "quick" ]; then
    run_step "make fmt-check" make fmt-check
    run_step "make lint" make lint
fi

# ── DEFAULT MODE (and full) ──────────────────────────────────────────
if [ "$MODE" = "default" ] || [ "$MODE" = "full" ]; then
    # make ci = fmt-check + lint + test + audit (defined in Makefile)
    run_step "make fmt-check" make fmt-check
    run_step "make lint (clippy all features)" make lint
    run_step "make test-cli" make test-cli
    run_step "make test-daemon" make test-daemon
    run_step "make test-integration" make test-integration

    # cargo audit (separate target)
    if command -v cargo-audit &>/dev/null; then
        run_step "make audit" make audit
    else
        skip "cargo audit" "cargo-audit not installed"
    fi

    # Truth alignment guardrails
    if [ -x "scripts/check-truth-alignment.sh" ]; then
        run_step "truth alignment" bash scripts/check-truth-alignment.sh
    else
        skip "truth alignment" "script not found"
    fi

    # Shellcheck on changed .sh files (staged + unstaged + vs origin/main)
    step_header "shellcheck (changed scripts)"
    CHANGED_SCRIPTS=""
    if git rev-parse --git-dir &>/dev/null; then
        # Include staged, unstaged, and diff vs origin/main if available
        CHANGED_SCRIPTS=$(
            {
                git diff --name-only HEAD 2>/dev/null || true
                git diff --cached --name-only 2>/dev/null || true
                git diff --name-only origin/main...HEAD 2>/dev/null || true
            } | grep -E '\.sh$' | sort -u || true
        )
    fi
    if [ -n "$CHANGED_SCRIPTS" ] && command -v shellcheck &>/dev/null; then
        logfile="$TMPDIR_CI/shellcheck.log"
        SC_FAIL=0
        while IFS= read -r script; do
            [ -f "$script" ] || continue
            echo "── $script ──" >> "$logfile"
            if ! shellcheck -S warning "$script" >> "$logfile" 2>&1; then
                SC_FAIL=1
            fi
        done <<< "$CHANGED_SCRIPTS"
        if [ "$SC_FAIL" -eq 0 ]; then
            pass "shellcheck"
        else
            fail "shellcheck" "$logfile"
        fi
    elif [ -z "$CHANGED_SCRIPTS" ]; then
        skip "shellcheck" "no .sh files changed"
    else
        skip "shellcheck" "not installed"
    fi
fi

# ── FULL MODE extras ─────────────────────────────────────────────────
if [ "$MODE" = "full" ]; then
    run_step "release build (cli + daemon)" make build

    # Hadolint on Containerfile
    step_header "hadolint Containerfile"
    if command -v hadolint &>/dev/null; then
        logfile="$TMPDIR_CI/hadolint.log"
        if hadolint --ignore DL3041 --ignore DL3008 image/Containerfile > "$logfile" 2>&1; then
            pass "hadolint"
        else
            fail "hadolint" "$logfile"
        fi
    else
        skip "hadolint" "not installed"
    fi
fi

# ── Report ───────────────────────────────────────────────────────────
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

printf "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
printf "${BOLD}  SUMMARY${NC}\n"
printf "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"

for r in "${RESULTS[@]}"; do
    printf "  %b\n" "$r"
done

printf "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
printf "  ${GREEN}Passed: %d${NC}   ${RED}Failed: %d${NC}   ${YELLOW}Skipped: %d${NC}   ${DIM}Time: %dm %ds${NC}\n" \
    "$PASSED" "$FAILED" "$SKIPPED" $((ELAPSED / 60)) $((ELAPSED % 60))

# ── Print failure logs ───────────────────────────────────────────────
if [ "$FAILED" -gt 0 ]; then
    printf "\n${RED}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    printf "${RED}${BOLD}  FAILURE DETAILS${NC}\n"
    printf "${RED}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"

    for entry in "${FAILED_LOGS[@]}"; do
        name="${entry%%|*}"
        logfile="${entry#*|}"
        printf "\n${RED}▼ %s${NC}\n" "$name"
        printf "${DIM}%s${NC}\n" "$(printf '%.0s─' {1..60})"
        if [ -f "$logfile" ]; then
            # Limit to last 80 lines per failure to avoid wall of text
            tail -n 80 "$logfile" | sed 's/^/  /'
            total=$(wc -l < "$logfile")
            if [ "$total" -gt 80 ]; then
                printf "  ${DIM}... (%d lines total, showing last 80 — full log: %s)${NC}\n" "$total" "$logfile"
            fi
        else
            printf "  ${DIM}(log file missing)${NC}\n"
        fi
    done
    printf "\n${RED}${BOLD}✗ DO NOT PUSH — fix %d failure(s) above first${NC}\n\n" "$FAILED"
    # Preserve logs for inspection if user wants
    KEEP_DIR="$PROJECT_ROOT/.local-ci-logs"
    mkdir -p "$KEEP_DIR"
    cp -r "$TMPDIR_CI"/* "$KEEP_DIR/" 2>/dev/null || true
    printf "${DIM}Full logs preserved at: %s${NC}\n\n" "$KEEP_DIR"
    exit 1
else
    printf "\n${GREEN}${BOLD}✓ ALL CLEAR — safe to push${NC}\n\n"
    exit 0
fi
