#!/bin/bash
# LifeOS Btrfs snapshot helper.
# Usage: lifeos-btrfs-snapshot.sh [label]
set -euo pipefail

LABEL="${1:-scheduled}"
SNAP_ROOT="/.snapshots"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
TARGET="${SNAP_ROOT}/${LABEL}-${TIMESTAMP}"

if ! command -v btrfs >/dev/null 2>&1; then
    echo "btrfs command not found; skipping snapshot"
    exit 0
fi

if [ "$(findmnt -n -o FSTYPE /)" != "btrfs" ]; then
    echo "Root filesystem is not btrfs; skipping snapshot"
    exit 0
fi

mkdir -p "${SNAP_ROOT}"

# Prefer having snapshots stored inside a dedicated subvolume.
if ! btrfs subvolume show "${SNAP_ROOT}" >/dev/null 2>&1; then
    btrfs subvolume create "${SNAP_ROOT}" >/dev/null 2>&1 || true
fi

if ! btrfs subvolume show / >/dev/null 2>&1; then
    echo "Root path is not a btrfs subvolume; skipping snapshot"
    exit 0
fi

btrfs subvolume snapshot -r / "${TARGET}"
echo "Created snapshot: ${TARGET}"
