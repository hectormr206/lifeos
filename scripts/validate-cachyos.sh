#!/usr/bin/env bash
# validate-cachyos.sh — LifeOS CachyOS V1 Acceptance Harness
#
# Validates the five acceptance scenarios (REQ-B1 through REQ-B5) defined in
# the cachyos-host-profile spec. Automated checks for B1–B3; interactive
# prompts for B4–B5.
#
# Usage:
#   ./scripts/validate-cachyos.sh [--json] [--verbose] [--help]
#
# Exit codes:
#   0  — All required checks (B1–B3) passed
#   1  — At least one required check failed
#   2  — Precondition error (lifeosd unreachable before any test)
#
# Dependencies: curl, jq, sqlite3 (optional), nvidia-smi (optional, B5 only)

set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

LIFEOS_PORT="${LIFEOS_PORT:-8081}"
LIFEOS_BASE="http://127.0.0.1:${LIFEOS_PORT}"
HEALTH_ENDPOINT="${LIFEOS_BASE}/api/v1/health"
CHAT_ENDPOINT="${LIFEOS_BASE}/api/v1/overlay/chat"
DASHBOARD_ENDPOINT="${LIFEOS_BASE}/dashboard"

# Dashboard SPA marker (from daemon/static/dashboard/index.html)
DASHBOARD_TITLE_MARKER="LifeOS"

# Bootstrap token: prefer env var, then try candidate paths in order.
# Mirrors bootstrap_runtime_dir_candidates() from daemon/src/main.rs.
TOKEN_CANDIDATES=(
    "${LIFEOS_RUNTIME_DIR:-}"
    "${XDG_RUNTIME_DIR:-}/lifeos"
    "${HOME:-}/.local/state/lifeos/runtime"
    "/run/lifeos"
)

# Memory DB path: prefer env var, then standard path.
MEMORY_DB="${LIFEOS_DATA_DIR:-/var/lib/lifeos}/memory.db"

# How long to wait for REQ-B3 memory fact to appear (seconds)
B3_WAIT_SECS=30

# Curl timeouts
CURL_CONNECT_TIMEOUT=10
CURL_MAX_TIME=30

# ---------------------------------------------------------------------------
# Globals (populated at runtime)
# ---------------------------------------------------------------------------

OPT_JSON=false
OPT_VERBOSE=false
BOOTSTRAP_TOKEN=""

# Results: associative array  req_id -> "PASS|FAIL|SKIPPED|INCONCLUSIVE|<reason>"
declare -A RESULTS
declare -A REASONS

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log_verbose() {
    if [[ "${OPT_VERBOSE}" == "true" ]]; then
        printf '[verbose] %s\n' "$*" >&2
    fi
}

# record <req_id> <status> <reason>
record() {
    local req="$1" status="$2" reason="$3"
    RESULTS["${req}"]="${status}"
    REASONS["${req}"]="${reason}"
}

# Print a single result line (plain text)
print_result_line() {
    local req="$1" status="${RESULTS[$1]}" reason="${REASONS[$1]}"
    printf '  %-6s  %-12s  %s\n' "${req}" "${status}" "${reason}"
}

# Resolve the bootstrap token from env or candidate paths.
resolve_token() {
    if [[ -n "${LIFEOS_BOOTSTRAP_TOKEN:-}" ]]; then
        BOOTSTRAP_TOKEN="${LIFEOS_BOOTSTRAP_TOKEN}"
        log_verbose "Bootstrap token: from LIFEOS_BOOTSTRAP_TOKEN env var"
        return 0
    fi

    for candidate in "${TOKEN_CANDIDATES[@]}"; do
        [[ -z "${candidate}" ]] && continue
        local token_file="${candidate}/bootstrap.token"
        if [[ -f "${token_file}" && -r "${token_file}" ]]; then
            BOOTSTRAP_TOKEN="$(< "${token_file}")"
            log_verbose "Bootstrap token: read from ${token_file}"
            return 0
        fi
    done

    return 1
}

# ---------------------------------------------------------------------------
# T27 — REQ-B1: Install Acceptance
# ---------------------------------------------------------------------------

check_b1() {
    printf '\n[B1] Install acceptance — GET %s\n' "${HEALTH_ENDPOINT}" >&2

    local http_code
    http_code=$(curl \
        --silent \
        --fail-with-body \
        --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
        --max-time "${CURL_MAX_TIME}" \
        -H "x-bootstrap-token: ${BOOTSTRAP_TOKEN}" \
        -o /dev/null \
        -w "%{http_code}" \
        "${HEALTH_ENDPOINT}" 2>/dev/null || true)

    log_verbose "HTTP response code: ${http_code}"

    if [[ "${http_code}" == "200" ]]; then
        record "B1" "PASS" "GET /api/v1/health returned 200"
    else
        record "B1" "FAIL" "GET /api/v1/health returned ${http_code} (expected 200)"
    fi
}

# ---------------------------------------------------------------------------
# T27 — REQ-B2: Dashboard Reachable
# ---------------------------------------------------------------------------

check_b2() {
    printf '\n[B2] Dashboard reachable — GET %s\n' "${DASHBOARD_ENDPOINT}" >&2

    local http_code response_body tmpfile
    tmpfile=$(mktemp /tmp/lifeos-validate-b2.XXXXXX)
    # shellcheck disable=SC2064
    trap "rm -f '${tmpfile}'" RETURN

    http_code=$(curl \
        --silent \
        --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
        --max-time "${CURL_MAX_TIME}" \
        -H "x-bootstrap-token: ${BOOTSTRAP_TOKEN}" \
        -o "${tmpfile}" \
        -w "%{http_code}" \
        "${DASHBOARD_ENDPOINT}?token=${BOOTSTRAP_TOKEN}" 2>/dev/null || true)

    log_verbose "HTTP response code: ${http_code}"

    if [[ "${http_code}" != "200" ]]; then
        record "B2" "FAIL" "Dashboard returned HTTP ${http_code} (expected 200)"
        return
    fi

    response_body=$(< "${tmpfile}")
    log_verbose "Response body (first 200 chars): ${response_body:0:200}"

    if echo "${response_body}" | grep -q "${DASHBOARD_TITLE_MARKER}"; then
        record "B2" "PASS" "HTTP 200 and SPA marker '${DASHBOARD_TITLE_MARKER}' found in body"
    else
        record "B2" "FAIL" "HTTP 200 but SPA marker '${DASHBOARD_TITLE_MARKER}' not found in body"
    fi
}

# ---------------------------------------------------------------------------
# T28 — REQ-B3: Memory Loop (health_fact_add)
# ---------------------------------------------------------------------------

check_b3() {
    printf '\n[B3] Memory loop — POST health fact, then query memory.db\n' >&2

    # Step 1: POST the message to Axi
    local test_message="soy alérgico a la lactosa"
    local http_code response_body tmpfile
    tmpfile=$(mktemp /tmp/lifeos-validate-b3.XXXXXX)
    # shellcheck disable=SC2064
    trap "rm -f '${tmpfile}'" RETURN

    local payload
    payload=$(printf '{"message": "%s"}' "${test_message}")

    log_verbose "POST ${CHAT_ENDPOINT} — payload: ${payload}"

    http_code=$(curl \
        --silent \
        --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
        --max-time "${CURL_MAX_TIME}" \
        -X POST \
        -H "Content-Type: application/json" \
        -H "x-bootstrap-token: ${BOOTSTRAP_TOKEN}" \
        -d "${payload}" \
        -o "${tmpfile}" \
        -w "%{http_code}" \
        "${CHAT_ENDPOINT}" 2>/dev/null || true)

    log_verbose "Chat HTTP response code: ${http_code}"
    response_body=$(< "${tmpfile}")
    log_verbose "Chat response (first 300 chars): ${response_body:0:300}"

    if [[ "${http_code}" != "200" ]]; then
        record "B3" "FAIL" "POST /api/v1/overlay/chat returned HTTP ${http_code} (expected 200)"
        return
    fi

    # Step 2: Poll memory.db for the health_fact row.
    #
    # The health_facts table schema (memory_plane.rs:157) has columns:
    #   fact_id, fact_type, label, severity, notes_nonce_b64,
    #   notes_ciphertext_b64, source_entry_id, created_at, updated_at
    #
    # The `label` column holds the human-readable fact. Notes are encrypted
    # (AES-GCM), so we only query plaintext columns.
    #
    # NOTE: memory.db uses application-layer encryption (AES-GCM) on the
    # notes_ciphertext_b64 field, but the database file itself is NOT
    # sqlcipher-encrypted — sqlite3 can open it directly. Only the `label`
    # and `fact_type` columns are plaintext-searchable.

    if [[ ! -f "${MEMORY_DB}" ]]; then
        # Try common fallback path (XDG)
        local xdg_db="${HOME:-}/.local/share/lifeos/memory.db"
        if [[ -f "${xdg_db}" ]]; then
            MEMORY_DB="${xdg_db}"
            log_verbose "Using XDG memory.db: ${MEMORY_DB}"
        else
            record "B3" "INCONCLUSIVE" \
                "Chat POST succeeded (HTTP 200) but memory.db not found at ${MEMORY_DB} or ${xdg_db}"
            return
        fi
    fi

    if ! command -v sqlite3 >/dev/null 2>&1; then
        record "B3" "INCONCLUSIVE" \
            "Chat POST succeeded (HTTP 200) but sqlite3 not installed; cannot verify DB row"
        return
    fi

    local elapsed=0
    local found_row=""
    local sql="SELECT fact_id, fact_type, label FROM health_facts \
WHERE LOWER(label) LIKE '%lactosa%' \
   OR LOWER(label) LIKE '%lactose%' \
   OR LOWER(fact_type) LIKE '%alergia%' \
   OR LOWER(fact_type) LIKE '%allergy%' \
LIMIT 1;"

    log_verbose "Polling memory.db for up to ${B3_WAIT_SECS}s"
    log_verbose "SQL: ${sql}"

    while [[ ${elapsed} -lt ${B3_WAIT_SECS} ]]; do
        found_row=$(sqlite3 "${MEMORY_DB}" "${sql}" 2>/dev/null || true)
        if [[ -n "${found_row}" ]]; then
            break
        fi
        sleep 2
        elapsed=$(( elapsed + 2 ))
        log_verbose "Elapsed: ${elapsed}s, still polling…"
    done

    if [[ -n "${found_row}" ]]; then
        log_verbose "Found row: ${found_row}"
        record "B3" "PASS" \
            "health_facts row found within ${elapsed}s: $(echo "${found_row}" | head -c 80)"
    else
        record "B3" "FAIL" \
            "No matching row in health_facts after ${B3_WAIT_SECS}s (POST returned 200)"
    fi
}

# ---------------------------------------------------------------------------
# T29 — REQ-B4: SimpleX Remote Loop (interactive)
# ---------------------------------------------------------------------------

check_b4() {
    printf '\n[B4] SimpleX remote loop (interactive)\n' >&2
    printf '  lifeos-simplex-bridge must be running and paired.\n' >&2
    printf '\n' >&2
    printf '  Procedure:\n' >&2
    printf '    1. Open SimpleX Chat on your phone or another device.\n' >&2
    printf '    2. Ensure your account is paired with Axi (lifeos-simplex-bridge).\n' >&2
    printf '       If not paired: run  lifeos-quadlet-install --user  then check\n' >&2
    printf '       journalctl --user -u lifeos-simplex-bridge.service  for the QR\n' >&2
    printf '       code path or pairing command.\n' >&2
    printf '    3. Send any message from SimpleX to Axi (e.g., "hola").\n' >&2
    printf '    4. Wait up to 30 seconds for a reply.\n' >&2
    printf '\n' >&2

    local answer
    printf '  Did Axi reply within 30s? [y/n/s=skip]: ' >&2
    read -r answer

    case "${answer,,}" in
        y|yes)
            local context_answer
            printf '  Did the reply reference prior conversation context? [y/n]: ' >&2
            read -r context_answer
            if [[ "${context_answer,,}" == y* ]]; then
                record "B4" "PASS" "User confirmed: SimpleX reply received with context-awareness"
            else
                record "B4" "PASS" \
                    "User confirmed: SimpleX reply received (context-awareness not verified)"
            fi
            ;;
        s|skip)
            record "B4" "SKIPPED" "User chose to skip SimpleX check"
            ;;
        n|no)
            record "B4" "FAIL" "User confirmed: no SimpleX reply received within 30s"
            ;;
        *)
            record "B4" "INCONCLUSIVE" "Unrecognized input: '${answer}'"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# T29 — REQ-B5: GPU Game Guard (interactive, with fallback)
# ---------------------------------------------------------------------------

check_b5() {
    printf '\n[B5] GPU Game Guard\n' >&2

    # Hardware probe: skip or degrade if no NVIDIA GPU
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        record "B5" "INCONCLUSIVE" \
            "nvidia-smi not found — Game Guard cannot be exercised; feature should be labeled experimental"
        printf '  NOTE: No NVIDIA GPU detected. Game Guard is EXPERIMENTAL on this host.\n' >&2
        printf '        The README must label Game Guard as "experimental".\n' >&2
        printf '        See docs/operations/runtime-install.md §5.5 for manual test procedure.\n' >&2
        return
    fi

    printf '  NVIDIA GPU detected. Proceeding with interactive Game Guard validation.\n' >&2
    printf '\n' >&2
    printf '  Procedure:\n' >&2
    printf '    1. Confirm lifeosd is running with Qwen3.5-9B on GPU:\n' >&2
    printf '         journalctl --user -u lifeosd.service -n 20 | grep -i "llama\\|profile\\|9b"\n' >&2
    printf '    2. Launch a game via Steam, OR run the GPU stress proxy:\n' >&2
    printf '         stress-ng --cpu-method matrixprod --vm 1 --vm-bytes 4G &\n' >&2
    printf '       (Note: stress-ng proxy may not trigger the game-process heuristic;\n' >&2
    printf '        a real Steam game launch is the authoritative test.)\n' >&2
    printf '    3. Within 10 seconds, check the journal:\n' >&2
    printf '         journalctl --user -u lifeosd.service -n 30 | grep "game guard"\n' >&2
    printf '       Expected: "game guard: swap to 4B CPU"\n' >&2
    printf '\n' >&2

    local swap_answer
    printf '  Did the journal show "game guard: swap to 4B CPU" within 10s? [y/n/s=skip]: ' >&2
    read -r swap_answer

    case "${swap_answer,,}" in
        s|skip)
            record "B5" "SKIPPED" "User chose to skip Game Guard swap check"
            return
            ;;
        n|no)
            record "B5" "FAIL" "Journal did not show game guard swap within 10s"
            return
            ;;
        y|yes)
            ;;
        *)
            record "B5" "INCONCLUSIVE" "Unrecognized input for swap check: '${swap_answer}'"
            return
            ;;
    esac

    printf '\n' >&2
    printf '    4. Stop the game (or kill stress-ng).\n' >&2
    printf '    5. Within 30 seconds, check the journal:\n' >&2
    printf '         journalctl --user -u lifeosd.service -n 30 | grep "game guard"\n' >&2
    printf '       Expected: "game guard: restore to 9B GPU"\n' >&2
    printf '\n' >&2

    local restore_answer
    printf '  Did the journal show "game guard: restore to 9B GPU" within 30s? [y/n/s=skip]: ' >&2
    read -r restore_answer

    case "${restore_answer,,}" in
        y|yes)
            record "B5" "PASS" \
                "User confirmed: game guard swap AND restore logged in journal"
            ;;
        s|skip)
            record "B5" "INCONCLUSIVE" \
                "Swap confirmed but restore check skipped"
            ;;
        n|no)
            record "B5" "FAIL" \
                "Swap confirmed but restore log not seen within 30s"
            ;;
        *)
            record "B5" "INCONCLUSIVE" "Unrecognized input for restore check: '${restore_answer}'"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

emit_plain() {
    printf '\n'
    printf '========================================\n'
    printf 'LifeOS CachyOS V1 Acceptance Results\n'
    printf '========================================\n'
    printf '  %-6s  %-12s  %s\n' "REQ" "STATUS" "REASON"
    printf '  %-6s  %-12s  %s\n' "------" "------------" "------"
    for req in B1 B2 B3 B4 B5; do
        if [[ -n "${RESULTS[${req}]:-}" ]]; then
            print_result_line "${req}"
        else
            printf '  %-6s  %-12s  %s\n' "${req}" "NOT_RUN" "(not executed)"
        fi
    done
    printf '\n'
}

emit_json() {
    if ! command -v jq >/dev/null 2>&1; then
        # Fallback: hand-craft JSON without jq
        printf '[\n'
        local first=true
        for req in B1 B2 B3 B4 B5; do
            local status="${RESULTS[${req}]:-NOT_RUN}"
            local reason="${REASONS[${req}]:-not executed}"
            [[ "${first}" == "true" ]] || printf ',\n'
            first=false
            # Escape double-quotes and backslashes in reason
            reason="${reason//\\/\\\\}"
            reason="${reason//\"/\\\"}"
            printf '  {"req": "%s", "status": "%s", "reason": "%s"}' \
                "${req}" "${status,,}" "${reason}"
        done
        printf '\n]\n'
        return
    fi

    local entries="[]"
    for req in B1 B2 B3 B4 B5; do
        local status="${RESULTS[${req}]:-NOT_RUN}"
        local reason="${REASONS[${req}]:-not executed}"
        entries=$(jq \
            --arg req "${req}" \
            --arg status "${status,,}" \
            --arg reason "${reason}" \
            '. + [{"req": $req, "status": $status, "reason": $reason}]' \
            <<< "${entries}")
    done
    printf '%s\n' "${entries}"
}

# Determine exit code: 0 if all of B1/B2/B3 are PASS, else 1.
compute_exit_code() {
    local required_reqs=("B1" "B2" "B3")
    for req in "${required_reqs[@]}"; do
        local status="${RESULTS[${req}]:-NOT_RUN}"
        if [[ "${status}" != "PASS" ]]; then
            return 1
        fi
    done
    return 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

usage() {
    cat >&2 <<'EOF'
Usage: validate-cachyos.sh [OPTIONS]

Validates the LifeOS CachyOS V1 acceptance scenarios (REQ-B1 through REQ-B5).

Options:
  --json      Emit results as a JSON array instead of plain text
  --verbose   Print curl status codes, SQL queries, and poll progress
  --help      Show this help message

Exit codes:
  0  All required checks (B1–B3) passed
  1  At least one required check (B1–B3) failed or is INCONCLUSIVE
  2  Precondition error (cannot resolve bootstrap token)

Environment:
  LIFEOS_BOOTSTRAP_TOKEN   Bootstrap token (overrides file lookup)
  LIFEOS_RUNTIME_DIR       Runtime dir where bootstrap.token is written
  LIFEOS_DATA_DIR          Data dir containing memory.db (default: /var/lib/lifeos)
  LIFEOS_PORT              Daemon HTTP port (default: 8081)
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)    OPT_JSON=true ;;
            --verbose) OPT_VERBOSE=true ;;
            --help|-h) usage; exit 0 ;;
            *) printf 'Unknown option: %s\n' "$1" >&2; usage; exit 2 ;;
        esac
        shift
    done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    parse_args "$@"

    printf 'LifeOS CachyOS Validation Harness\n' >&2
    printf 'Scenarios: REQ-B1 (install) B2 (dashboard) B3 (memory) B4 (simplex) B5 (game guard)\n' >&2
    printf '\n' >&2

    # Resolve bootstrap token — required for B1 and B2.
    if ! resolve_token; then
        printf 'ERROR: Cannot locate bootstrap token.\n' >&2
        printf 'Set LIFEOS_BOOTSTRAP_TOKEN env var, or ensure lifeosd has run at least once\n' >&2
        printf 'so it writes the token to one of:\n' >&2
        printf '  %s/lifeos/bootstrap.token\n' "${XDG_RUNTIME_DIR:-\$XDG_RUNTIME_DIR}" >&2
        printf '  %s/.local/state/lifeos/runtime/bootstrap.token\n' "${HOME:-\$HOME}" >&2
        printf '  /run/lifeos/bootstrap.token\n' >&2
        exit 2
    fi

    log_verbose "Resolved bootstrap token (length=${#BOOTSTRAP_TOKEN})"

    # Run all checks.
    check_b1
    check_b2
    check_b3
    check_b4
    check_b5

    # Emit results.
    if [[ "${OPT_JSON}" == "true" ]]; then
        emit_json
    else
        emit_plain
    fi

    # Exit code based on required checks (B1–B3).
    compute_exit_code
}

main "$@"
