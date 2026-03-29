#!/bin/bash
# Check that test coverage hasn't decreased.
# Requires: cargo-tarpaulin or cargo-llvm-cov
set -euo pipefail

COVERAGE_FILE=".coverage-baseline"
THRESHOLD=1  # Allow 1% drop

if ! command -v cargo-tarpaulin &>/dev/null; then
    echo "SKIP: cargo-tarpaulin not installed"
    echo "Install with: cargo install cargo-tarpaulin"
    exit 0
fi

# Run coverage
CURRENT=$(cargo tarpaulin -p lifeosd --skip-clean --out json 2>/dev/null | \
    python3 -c "import json,sys; print(f'{json.load(sys.stdin)[\"coverage_percent\"]:.1f}')" 2>/dev/null || echo "0.0")

echo "Current coverage: ${CURRENT}%"

if [ -f "$COVERAGE_FILE" ]; then
    BASELINE=$(cat "$COVERAGE_FILE")
    echo "Baseline: ${BASELINE}%"

    # Check if coverage dropped
    DROP=$(python3 -c "print(f'{float(\"$BASELINE\") - float(\"$CURRENT\"):.1f}')")
    if python3 -c "exit(0 if float('$DROP') <= $THRESHOLD else 1)"; then
        echo "OK: Coverage within threshold (drop: ${DROP}%)"
    else
        echo "FAIL: Coverage dropped by ${DROP}% (threshold: ${THRESHOLD}%)"
        exit 1
    fi
fi

# Save current as new baseline
echo "$CURRENT" > "$COVERAGE_FILE"
echo "Baseline updated to ${CURRENT}%"
