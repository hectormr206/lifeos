#!/bin/bash
# Scope-aware CI — only build/test what changed
set -euo pipefail

CHANGED=$(git diff --name-only HEAD~1 2>/dev/null || git diff --name-only --cached)

BUILD_CLI=false
BUILD_DAEMON=false
RUN_TESTS=false
LINT_ONLY=false

for file in $CHANGED; do
    case "$file" in
        cli/*)          BUILD_CLI=true; RUN_TESTS=true ;;
        daemon/*)       BUILD_DAEMON=true; RUN_TESTS=true ;;
        tests/*)        RUN_TESTS=true ;;
        image/*)        echo "IMAGE: $file changed — rebuild ISO needed" ;;
        docs/*)         LINT_ONLY=true ;;
        scripts/*)      echo "SCRIPT: $file changed — review manually" ;;
        Cargo.*)        BUILD_CLI=true; BUILD_DAEMON=true; RUN_TESTS=true ;;
    esac
done

echo "=== Scope-aware CI ==="
echo "Build CLI: $BUILD_CLI"
echo "Build Daemon: $BUILD_DAEMON"
echo "Run Tests: $RUN_TESTS"

if [ "$BUILD_DAEMON" = "true" ]; then
    echo "--- Building daemon ---"
    cargo build --manifest-path daemon/Cargo.toml
fi

if [ "$BUILD_CLI" = "true" ]; then
    echo "--- Building CLI ---"
    cargo build --manifest-path cli/Cargo.toml
fi

if [ "$RUN_TESTS" = "true" ]; then
    echo "--- Running tests ---"
    [ "$BUILD_DAEMON" = "true" ] && cargo test -p lifeosd
    [ "$BUILD_CLI" = "true" ] && cargo test -p life
fi

if [ "$LINT_ONLY" = "true" ] && [ "$RUN_TESTS" = "false" ]; then
    echo "--- Docs-only change, skipping build ---"
fi

echo "=== Done ==="
