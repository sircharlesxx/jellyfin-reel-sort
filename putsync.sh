#!/bin/bash

# Configuration file support — search in priority order:
#   1. Explicit env var (e.g. set in crontab)
#   2. /etc system-wide config
#   3. Any user's ~/.config/jellyfin-reel-sort.conf (handles sudo/root runs)
CONFIG_FILE="${JELLYFIN_SORT_CONFIG:-}"

if [ -z "$CONFIG_FILE" ] || [ ! -f "$CONFIG_FILE" ]; then
    if [ -f "/etc/jellyfin-reel-sort.conf" ]; then
        CONFIG_FILE="/etc/jellyfin-reel-sort.conf"
    else
        # Search all real user home directories for the config
        for homedir in /home/*/; do
            candidate="$homedir.config/jellyfin-reel-sort.conf"
            if [ -f "$candidate" ]; then
                CONFIG_FILE="$candidate"
                break
            fi
        done
    fi
fi

if [ -f "$CONFIG_FILE" ]; then
    export JELLYFIN_SORT_CONFIG="$CONFIG_FILE"
    set -a
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    set +a
    # Derive the config owner's home dir for venv resolution below
    CONFIG_OWNER_HOME="$(dirname "$(dirname "$CONFIG_FILE")")"
else
    CONFIG_OWNER_HOME="$HOME"
fi

# Lazy auto-detection for rclone remote if not explicitly specified
if [ -z "$REMOTE_NAME" ]; then
    if command -v rclone > /dev/null 2>&1; then
        # Check if 'put.io' exists, or any remote with 'put' in it, or use the first available remote
        while IFS= read -r rem; do
            clean_rem="${rem%:}"
            if [[ "$clean_rem" =~ [Pp][Uu][Tt] ]]; then
                REMOTE_NAME="$clean_rem"
                break
            elif [ -z "$REMOTE_NAME" ] && [ -n "$clean_rem" ]; then
                REMOTE_NAME="$clean_rem"
            fi
        done < <(rclone listremotes 2>/dev/null || true)
    fi
fi
REMOTE_NAME="${REMOTE_NAME:-put.io}"

LOCAL_PATH="${DOWNLOADS_DIR:-/home/mariofishy/Jellyfin/downloads/}"
LOG_FILE="${LOG_FILE:-/var/log/jellyfin-reel-sort.log}"
LOCK_FILE="${LOCK_FILE:-/tmp/jellyfin_reel_sort.lock}"
SORTER_SCRIPT="${SORTER_PATH:-$(dirname "$0")/sorter.py}"
EXCLUDE_FILE="${EXCLUDE_FILE:-${CONFIG_OWNER_HOME}/.local/state/jellyfin-reel-sort/exclude_list.txt}"
mkdir -p "$(dirname "$EXCLUDE_FILE")" 2>/dev/null || true
touch "$EXCLUDE_FILE" 2>/dev/null || true
export EXCLUDE_FILE

# Resolve Python interpreter — check config's venv first, then system python3
if [ -n "$PYTHON_BIN" ] && [ -x "$PYTHON_BIN" ]; then
    PY_CMD="$PYTHON_BIN"
elif [ -x "$CONFIG_OWNER_HOME/.local/share/jellyfin-reel-sort/venv/bin/python3" ]; then
    PY_CMD="$CONFIG_OWNER_HOME/.local/share/jellyfin-reel-sort/venv/bin/python3"
else
    PY_CMD="$(command -v python3)"
fi

# Ensure log dir exists
LOG_DIR="$(dirname "$LOG_FILE")"
mkdir -p "$LOG_DIR" 2>/dev/null || true

# Clean up lock file on exit (normal, error, or signal) so stale locks
# owned by root never block future runs
cleanup() {
    rm -f "$LOCK_FILE"
}
trap cleanup EXIT INT TERM

# Prevent script from running more than once concurrently
(
  flock -n 200 || { echo "Already running — exiting." >> "$LOG_FILE"; exit 1; }

  echo "--- Starting $REMOTE_NAME copy job at $(date) ---" >> "$LOG_FILE"

  # Sync exclusion list with Jellyfin library before copy:
  # If a title was deleted from Jellyfin, un-exclude it so it can be re-downloaded
  "$PY_CMD" "$SORTER_SCRIPT" --prune-excludes >> "$LOG_FILE" 2>&1 || true

  if command -v rclone > /dev/null 2>&1; then
    rclone copy "$REMOTE_NAME:/" "$LOCAL_PATH" \
      --progress \
      --exclude-from "$EXCLUDE_FILE" \
      --log-file="$LOG_FILE"

    # Fix ownership so the downloads folder owner can read files even
    # when rclone ran as root (works on any rclone version)
    MEDIA_OWNER="$(stat -c '%U' "$LOCAL_PATH" 2>/dev/null || echo '')"
    if [ -n "$MEDIA_OWNER" ] && [ "$MEDIA_OWNER" != "root" ]; then
      chown -R "$MEDIA_OWNER" "$LOCAL_PATH" 2>/dev/null || true
    fi
  else
    echo "Warning: rclone not found in PATH. Skipping remote copy." >> "$LOG_FILE"
  fi

  echo "--- Copy job finished at $(date) ---" >> "$LOG_FILE"
  echo "" >> "$LOG_FILE"

  echo "--- Starting sort and hardlink at $(date) ---" >> "$LOG_FILE"

  "$PY_CMD" "$SORTER_SCRIPT" >> "$LOG_FILE" 2>&1

  echo "--- Copy and Sort jobs finished at $(date) ---" >> "$LOG_FILE"
  echo "" >> "$LOG_FILE"

) 200>"$LOCK_FILE"
