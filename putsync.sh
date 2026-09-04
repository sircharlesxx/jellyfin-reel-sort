#!/bin/bash

# Configuration file support
CONFIG_FILE="${JELLYFIN_SORT_CONFIG:-/etc/jellyfin-reel-sort.conf}"

if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

REMOTE_NAME="${REMOTE_NAME:-put.io}"
LOCAL_PATH="${DOWNLOADS_DIR:-$HOME/Jellyfin/downloads/}"
LOG_FILE="${LOG_FILE:-/var/log/rclone_putio_copy.log}"
LOCK_FILE="${LOCK_FILE:-/tmp/rclone_putio.lock}"
SORTER_SCRIPT="${SORTER_PATH:-$(dirname "$0")/sorter.py}"

# Ensure log dir exists if writable
LOG_DIR="$(dirname "$LOG_FILE")"
if [ ! -d "$LOG_DIR" ] && [ -w "$(dirname "$LOG_DIR")" ]; then
    mkdir -p "$LOG_DIR"
fi

# Prevent script from running more than once concurrently
(
  flock -n 200 || exit 1

  echo "--- Starting put.io copy job at $(date) ---" >> "$LOG_FILE"

  if command -v rclone >/dev/null 2>&1; then
    rclone copy "$REMOTE_NAME:/" "$LOCAL_PATH" \
      --progress \
      --log-file="$LOG_FILE"
  else
    echo "Warning: rclone not found in PATH. Skipping remote copy." >> "$LOG_FILE"
  fi

  echo "--- Copy job finished at $(date) ---" >> "$LOG_FILE"
  echo "" >> "$LOG_FILE"

  echo "--- Starting blind sort and hardlink at $(date) ---" >> "$LOG_FILE"

  # Run python sorter
  python3 "$SORTER_SCRIPT" >> "$LOG_FILE" 2>&1

  echo "--- Copy and Sort jobs finished at $(date) ---" >> "$LOG_FILE"
  echo "" >> "$LOG_FILE"

) 200>"$LOCK_FILE"
