#!/bin/bash
# Refreshes /boot/loader/entries/*.conf titles to match each ostree deploy's PRETTY_NAME.
#
# bootc upgrade does not regenerate BLS entries when the kernel is unchanged
# across versions, so the title field can stay stale across version bumps
# (e.g. GRUB shows "LifeOS 0.8.11" while the running deploy is 0.8.16).
# This service runs at boot, reads PRETTY_NAME from each deploy's own
# /etc/os-release, and rewrites the title accordingly. Idempotent.

set -euo pipefail

BLS_DIR=/boot/loader/entries
DEPLOY_ROOT=/ostree/deploy/default/deploy

[ -d "$BLS_DIR" ] || exit 0
command -v bootc >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

bootc_status=$(bootc status --format=json 2>/dev/null) || exit 0

read_csum() {
    printf '%s' "$bootc_status" | python3 -c "
import json, sys
d = json.load(sys.stdin).get('status', {}).get('$1') or {}
print((d.get('ostree') or {}).get('checksum', ''))
"
}

booted_csum=$(read_csum booted)
rollback_csum=$(read_csum rollback)

declare -A CSUM_BY_IDX=( [0]="$booted_csum" [1]="$rollback_csum" )

shopt -s nullglob
for entry in "$BLS_DIR"/ostree-*.conf; do
    idx=$(grep -oE '\(ostree:[0-9]+\)' "$entry" | head -1 | grep -oE '[0-9]+' || true)
    [ -n "${idx:-}" ] || continue
    csum="${CSUM_BY_IDX[$idx]:-}"
    [ -n "$csum" ] || continue

    deploy_dir=$(printf '%s\n' "$DEPLOY_ROOT/$csum".[0-9]* 2>/dev/null | head -1)
    [ -d "$deploy_dir" ] || continue

    pretty=$(awk -F= '$1=="PRETTY_NAME"{val=$2; gsub(/^"|"$/, "", val); print val; exit}' \
                 "$deploy_dir/etc/os-release" 2>/dev/null || true)
    [ -n "$pretty" ] || continue

    new_title="title $pretty (ostree:$idx)"
    current_title=$(grep -E '^title ' "$entry" | head -1 || true)

    if [ "$current_title" != "$new_title" ]; then
        # /boot is mutable on bootc; write atomically.
        tmp=$(mktemp "$entry.XXXXXX")
        sed "s|^title .*|$new_title|" "$entry" > "$tmp"
        mv -f "$tmp" "$entry"
        chmod 0644 "$entry"
        echo "lifeos-refresh-bls-titles: $(basename "$entry") -> $new_title" >&2
    fi
done
