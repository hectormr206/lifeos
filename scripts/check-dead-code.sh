#!/bin/bash
# Check for orphaned Rust modules not wired to main.rs
set -euo pipefail
MAIN="daemon/src/main.rs"
SRC_DIR="daemon/src"
ERRORS=0

for file in "$SRC_DIR"/*.rs; do
    mod=$(basename "$file" .rs)
    [[ "$mod" == "main" ]] && continue

    # Check if module is declared in main.rs
    if ! grep -q "^mod $mod" "$MAIN" && ! grep -q "^pub mod $mod" "$MAIN"; then
        # Check if it's a test module or feature-gated
        if ! grep -q '#\[cfg(feature' "$file" && ! grep -q '#\[cfg(test' "$file"; then
            echo "ORPHAN: $file is not declared in main.rs"
            ERRORS=$((ERRORS + 1))
        fi
    fi
done

# Also check for #[allow(dead_code)] on mod declarations
DEAD=$(grep -c '#\[allow(dead_code)\]' "$MAIN" || true)
if [ "$DEAD" -gt 0 ]; then
    echo "WARNING: $DEAD modules have #[allow(dead_code)] in main.rs"
fi

if [ "$ERRORS" -eq 0 ]; then
    echo "OK: All modules are wired to main.rs"
else
    echo "FAIL: $ERRORS orphaned modules found"
    exit 1
fi
