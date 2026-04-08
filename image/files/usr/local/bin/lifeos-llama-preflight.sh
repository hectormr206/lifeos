#!/bin/bash
# Guard against crash loops when the shipped llama-server binary is not runnable
# on the target CPU (for example due to an incompatible instruction-set build).

set -euo pipefail

LLAMA_BIN="${1:-/usr/sbin/llama-server}"
STATE_DIR="/var/lib/lifeos"
REASON_FILE="${STATE_DIR}/llama-server-preflight.reason"

mkdir -p "$STATE_DIR"

write_reason() {
    local message="$1"

    printf '%s\n' "$message" | tee "$REASON_FILE" >&2
}

if [ ! -x "$LLAMA_BIN" ]; then
    write_reason "llama-server preflight: binary not found at $LLAMA_BIN; skipping service start"
    exit 1
fi

set +e
"$LLAMA_BIN" --version >/dev/null 2>&1
status=$?
set -e

case "$status" in
    0)
        rm -f "$REASON_FILE"
        exit 0
        ;;
    132)
        write_reason "llama-server preflight: '$LLAMA_BIN --version' exited with SIGILL (132). Most likely the shipped binary was built with CPU instructions unsupported by this machine. Skipping start to avoid a systemd crash loop. Rebuild the image with a portable llama.cpp CPU baseline (GGML_NATIVE=OFF)."
        exit 1
        ;;
    *)
        # Do not block startup on unrelated CLI/version quirks; the main process
        # will still produce the authoritative error if runtime startup fails.
        rm -f "$REASON_FILE"
        exit 0
        ;;
esac
