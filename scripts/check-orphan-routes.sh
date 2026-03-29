#!/bin/bash
# Check for API routes without tests
set -euo pipefail
API="daemon/src/api/mod.rs"
TEST_DIR="tests/"
ERRORS=0

# Extract route handler function names (async fn handle_*)
grep -oP 'async fn (handle_\w+|get_\w+|post_\w+|put_\w+|delete_\w+)' "$API" | while read -r _ func; do
    # Check if function is referenced in test files or in the router setup
    if ! grep -rq "$func" "$TEST_DIR" 2>/dev/null; then
        if ! grep -q ".$func" "$API" 2>/dev/null; then
            echo "UNTESTED: $func has no test reference"
            ERRORS=$((ERRORS + 1))
        fi
    fi
done

echo "Route check complete"
