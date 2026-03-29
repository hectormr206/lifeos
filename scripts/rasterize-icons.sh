#!/bin/bash
# Rasterize all SVG icons to fixed-size PNGs for legacy GTK3 apps.
# Requires: rsvg-convert (from librsvg2-tools) or inkscape
# Usage: ./rasterize-icons.sh
set -euo pipefail

THEME_DIR="image/files/usr/share/icons/LifeOS"
SIZES=(16 22 24 32 48 64 128 256)
COUNT=0

# Check for rsvg-convert
if ! command -v rsvg-convert &>/dev/null; then
    echo "ERROR: rsvg-convert not found. Install with:"
    echo "  sudo dnf install librsvg2-tools"
    echo "  # or: flatpak-spawn --host sudo dnf install librsvg2-tools"
    exit 1
fi

echo "=== Rasterizing SVG icons to PNG ==="

for ctx_dir in "$THEME_DIR/scalable"/*/; do
    ctx=$(basename "$ctx_dir")

    for svg_file in "$ctx_dir"*.svg; do
        [ -f "$svg_file" ] || continue
        # Skip symbolic variants
        [[ "$svg_file" == *-symbolic.svg ]] && continue

        base=$(basename "$svg_file" .svg)

        for size in "${SIZES[@]}"; do
            png_dir="$THEME_DIR/${size}x${size}/${ctx}"
            png_file="$png_dir/${base}.png"

            [ -f "$png_file" ] && continue

            mkdir -p "$png_dir"
            rsvg-convert -w "$size" -h "$size" "$svg_file" -o "$png_file"
            COUNT=$((COUNT + 1))
        done
    done

    echo "  $ctx: done"
done

echo ""
echo "Generated: $COUNT PNGs"
echo ""
echo "NOTE: Update index.theme to add [NxN/context] sections for each size."
echo "Run: gtk-update-icon-cache $THEME_DIR/ to refresh cache."
