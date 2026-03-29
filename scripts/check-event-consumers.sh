#!/bin/bash
# Check that every DaemonEvent variant has at least one consumer
set -euo pipefail
EVENTS="daemon/src/events.rs"
SRC_DIR="daemon/src"

# Extract event variants from the enum
grep -oP '^\s+(\w+)\s*\{' "$EVENTS" | sed 's/[{ ]//g' | while read variant; do
    # Search for match arms that consume this variant
    CONSUMERS=$(grep -rl "DaemonEvent::$variant" "$SRC_DIR" --include="*.rs" | grep -v events.rs | wc -l)
    if [ "$CONSUMERS" -eq 0 ]; then
        echo "UNCONSUMED: DaemonEvent::$variant has no consumer"
    fi
done

echo "Event consumer check complete"
