#!/usr/bin/env bash
# lifeos-pre-update-snapshot.sh
# Called by life update or systemd before bootc updates
# Ensures system state is snapshotted via btrfs

set -e

if ! command -v btrfs &> /dev/null; then
    echo "Btrfs not found. Skipping snapshot."
    exit 0
fi

# LifeOS uses bootc which handles rollback via OSTree/composefs,
# but btrfs snapshots of /var and /home are essential to avoid data drift.
MOUNT_POINT="/var"
SNAPSHOT_DIR="/var/snapshots"

mkdir -p "$SNAPSHOT_DIR"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
SNAPSHOT_NAME="pre-update-var-$TIMESTAMP"

echo "Taking Btrfs snapshot of $MOUNT_POINT before update..."
if btrfs subvolume show "$MOUNT_POINT" &>/dev/null; then
    btrfs subvolume snapshot "$MOUNT_POINT" "$SNAPSHOT_DIR/$SNAPSHOT_NAME"
    echo "Snapshot $SNAPSHOT_NAME created successfully."
else
    echo "Warning: $MOUNT_POINT is not a btrfs subvolume. Skipping."
fi
