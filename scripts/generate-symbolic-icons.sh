#!/bin/bash
# Generate symbolic variants of ALL LifeOS icons.
# Symbolic icons are monochrome SVGs that GTK/libcosmic recolors automatically
# based on the active theme (dark/light). They use CSS classes instead of
# hardcoded colors, falling back to a single fill color.
#
# Freedesktop spec: symbolic icons use currentColor or a neutral fill
# that the toolkit overrides. For COSMIC/GTK4, we use fill="currentColor"
# with a class that the toolkit maps to the foreground color.
set -euo pipefail

ICON_DIR="image/files/usr/share/icons/LifeOS/scalable"
SYMB_BASE="image/files/usr/share/icons/LifeOS"
COUNT=0

echo "=== Generating symbolic variants ==="

for ctx_dir in "$ICON_DIR"/*/; do
    ctx=$(basename "$ctx_dir")
    symb_dir="$SYMB_BASE/scalable/${ctx}"

    for svg_file in "$ctx_dir"*.svg; do
        [ -f "$svg_file" ] || continue
        base=$(basename "$svg_file" .svg)
        symb_file="$symb_dir/${base}-symbolic.svg"

        # Skip if symbolic already exists
        [ -f "$symb_file" ] && continue

        # Convert to monochrome: replace all fill/stroke colors with #E8E8E8
        # and set opacity variations for depth (keep existing opacity attributes)
        sed \
            -e 's/fill="#[0-9A-Fa-f]\{6\}"/fill="#E8E8E8"/g' \
            -e 's/stroke="#[0-9A-Fa-f]\{6\}"/stroke="#E8E8E8"/g' \
            -e 's/fill="none"/fill="none"/g' \
            -e 's/stroke="none"/stroke="none"/g' \
            "$svg_file" > "$symb_file"

        COUNT=$((COUNT + 1))
    done

    CTX_COUNT=$(find "$symb_dir" -name "*-symbolic.svg" 2>/dev/null | wc -l)
    echo "  $ctx: $CTX_COUNT symbolic variants"
done

echo ""
echo "Generated: $COUNT symbolic variants"
echo "Total files in theme: $(find "$SYMB_BASE" -name "*.svg" | wc -l)"
