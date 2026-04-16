#!/usr/bin/env bash
# assert-no-piper.sh
# Asserts that a filesystem tree or individual files do NOT contain any Piper
# TTS artifacts that must never appear in production LifeOS images after the
# migration to Kokoro TTS.
#
# Usage:
#   assert-no-piper.sh <file-or-dir> [file-or-dir ...]
#
# Arguments:
#   One or more files or directories to check.
#   - Files are scanned for forbidden strings using rg.
#   - Directories are walked recursively with fd (all files).
#
# Exit codes:
#   0 — No Piper artifacts found.
#   1 — One or more forbidden Piper artifacts found (offending lines printed).
#   2 — Usage error (no argument provided).
#
# Forbidden filesystem paths (presence in a directory tree → exit 1):
#   usr/local/bin/lifeos-piper
#   usr/share/lifeos/models/piper/
#   opt/lifeos/piper-tts/
#   etc/systemd/user/lifeosd.service.d/LIFEOS_TTS_*.conf
#
# Forbidden strings in files (any match → exit 1):
#   piper-voice-builder
#   piper-runtime-builder
#   lifeos-piper
#   es_MX-claude
#   LIFEOS_TTS_BIN
#   LIFEOS_TTS_MODEL
#   LIFEOS_TTS_FALLBACK_BIN

set -euo pipefail

# ── Forbidden filesystem path suffixes ───────────────────────────────────────
readonly FORBIDDEN_PATH_PATTERNS=(
    "usr/local/bin/lifeos-piper"
    "usr/share/lifeos/models/piper"
    "opt/lifeos/piper-tts"
    "etc/systemd/user/lifeosd.service.d/LIFEOS_TTS_"
)

# ── Forbidden strings in file content ────────────────────────────────────────
# These are matched as literal strings (not regex) via rg -F
readonly FORBIDDEN_STRINGS=(
    "piper-voice-builder"
    "piper-runtime-builder"
    "lifeos-piper"
    "es_MX-claude"
    "LIFEOS_TTS_BIN"
    "LIFEOS_TTS_MODEL"
    "LIFEOS_TTS_FALLBACK_BIN"
)

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
    cat >&2 <<'EOF'
Usage: assert-no-piper.sh <file-or-dir> [file-or-dir ...]

Assert that LifeOS image files / Containerfile contain no Piper TTS artifacts.

Arguments:
  One or more files or directories. Directories are walked recursively.

Exit codes:
  0  No Piper artifacts found.
  1  One or more Piper artifacts found (offending paths/lines printed to stdout).
  2  Usage error.

Forbidden filesystem paths:
  usr/local/bin/lifeos-piper
  usr/share/lifeos/models/piper/
  opt/lifeos/piper-tts/
  etc/systemd/user/lifeosd.service.d/LIFEOS_TTS_*.conf

Forbidden strings in files:
  piper-voice-builder, piper-runtime-builder, lifeos-piper, es_MX-claude,
  LIFEOS_TTS_BIN, LIFEOS_TTS_MODEL, LIFEOS_TTS_FALLBACK_BIN
EOF
}

if [ $# -eq 0 ]; then
    usage
    exit 2
fi

FOUND=0

# ── Build rg pattern from forbidden strings ───────────────────────────────────
# Join with | for a single rg pass per file (faster than multiple rg invocations)
RG_PATTERN=""
for s in "${FORBIDDEN_STRINGS[@]}"; do
    if [ -z "${RG_PATTERN}" ]; then
        RG_PATTERN="${s}"
    else
        RG_PATTERN="${RG_PATTERN}|${s}"
    fi
done

# ── Scan a single regular file ─────────────────────────────────────────────────
scan_file() {
    local file="$1"

    # Skip binary files — rg handles this automatically with --text not set
    # (rg skips binary by default unless a match is in a binary file, then it
    # just notes "binary file matches". We use -l to avoid that output and
    # then a second pass for line-level output.)

    set +e
    matches=$(rg -n --no-heading -e "${RG_PATTERN}" -- "${file}" 2>/dev/null)
    rg_rc=$?
    set -e

    if [ "${rg_rc}" -eq 0 ] && [ -n "${matches}" ]; then
        echo "FAIL: piper string found in ${file}:"
        while IFS= read -r line; do
            echo "  ${line}"
        done <<< "${matches}"
        FOUND=$((FOUND + 1))
    fi
}

# ── Check forbidden paths under a directory root ───────────────────────────────
check_forbidden_paths() {
    local root="$1"

    for pattern in "${FORBIDDEN_PATH_PATTERNS[@]}"; do
        # Use fd to find any path that contains the pattern as a substring
        # fd returns exit 0 whether or not it found anything; capture output
        set +e
        hits=$(fd --unrestricted --type f --type d . "${root}" 2>/dev/null \
               | { grep -F "${pattern}" || true; })
        set -e

        if [ -n "${hits}" ]; then
            echo "FAIL: forbidden Piper path found:"
            while IFS= read -r hit; do
                echo "  ${hit}"
            done <<< "${hits}"
            FOUND=$((FOUND + 1))
        fi
    done

    # Also check for the LIFEOS_TTS_*.conf glob pattern (fd glob)
    set +e
    conf_hits=$(fd --unrestricted 'LIFEOS_TTS_.*\.conf$' "${root}" 2>/dev/null || true)
    set -e
    if [ -n "${conf_hits}" ]; then
        echo "FAIL: forbidden LIFEOS_TTS_*.conf drop-in found:"
        while IFS= read -r hit; do
            echo "  ${hit}"
        done <<< "${conf_hits}"
        FOUND=$((FOUND + 1))
    fi
}

# ── Process each argument ──────────────────────────────────────────────────────
for target in "$@"; do
    if [ -d "${target}" ]; then
        # Directory: check forbidden paths and scan all regular files
        check_forbidden_paths "${target}"

        # Walk all regular files and scan for forbidden strings
        while IFS= read -r -d '' file; do
            scan_file "${file}"
        done < <(fd --unrestricted --type f . "${target}" --print0 2>/dev/null || true)

    elif [ -f "${target}" ]; then
        scan_file "${target}"
    else
        echo "WARNING: target does not exist or is not a file/dir: ${target}" >&2
    fi
done

# ── Result ─────────────────────────────────────────────────────────────────────
if [ "${FOUND}" -gt 0 ]; then
    echo ""
    echo "FAIL: ${FOUND} piper artifact(s) found — see above."
    exit 1
fi

echo "PASS: no piper artifacts found."
exit 0
