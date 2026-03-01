#!/bin/bash
# llama-server health check for LifeOS
set -e

LLAMA_URL="${LLAMA_URL:-http://localhost:8082}"
TIMEOUT="${TIMEOUT:-5}"

if ! curl -fsSL --max-time "$TIMEOUT" "${LLAMA_URL}/health" > /dev/null 2>&1; then
    echo "ERROR: llama-server not responding"
    exit 1
fi

echo "OK: llama-server is running"

if [ "${1:-}" = "--verbose" ] || [ "${1:-}" = "-v" ]; then
    PROPS=$(curl -fsSL --max-time "$TIMEOUT" "${LLAMA_URL}/props" 2>/dev/null || echo "{}")
    echo "Server info: $PROPS"
    echo "Models in /var/lib/lifeos/models/:"
    ls -lh /var/lib/lifeos/models/*.gguf 2>/dev/null || echo "  (none)"
fi

exit 0
