#!/usr/bin/env bash
set -euo pipefail

MOUNTPOINT="$HOME/Cloud"

mkdir -p "$MOUNTPOINT"

# If already mounted, do nothing
# if mountpoint -q "$MOUNTPOINT"; then
#   exit 0
# fi

# If it's currently a mount (even if broken), unmount lazily
if mountpoint -q "$MOUNTPOINT"; then
  fusermount3 -u -z "$MOUNTPOINT" 2>/dev/null || umount -l "$MOUNTPOINT" 2>/dev/null || true
fi

# (Optional) wait a bit for network if your session races network
sleep 2

# Mount
exec rclone mount \
  --gid=1002 --uid=1000 \
  --timeout=1h \
  --poll-interval=15s \
  --vfs-cache-mode=writes \
  --vfs-cache-max-size=150G \
  --vfs-cache-max-age=12h \
  --drive-export-formats "url" \
  shawnschwartzcomgdrive: "$MOUNTPOINT"
