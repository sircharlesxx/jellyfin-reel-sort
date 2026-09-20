#!/bin/bash

# ==============================================================================
# Jellyfin Reel Sort — Main Put.io Ingest & Sort Pipeline
#
# Standardized Automated Pipeline:
#   1. Lock & Concurrency: Prevents overlapping runs via non-blocking flock.
#   2. User & Config: Automatically targets user (mariofishy) & loads ~/.config.
#   3. Cloud Ingest: rclone copy from Put.io remote to ~/Jellyfin/downloads/.
#   4. Permission Management: Fixes ownership for mariofishy on root cron runs.
#   5. Media Hardlink & Sort: Runs sorter.py to link into Shows/ and Movies/.
#   6. Library Notification: Signals Jellyfin to scan for newly organized media.
# ==============================================================================

# 1. Prevent concurrent runs using non-blocking lock
LOCK_FILE="${LOCK_FILE:-/tmp/jellyfin_reel_sort.lock}"
trap 'rm -f "$LOCK_FILE"' EXIT INT TERM
exec 200>"$LOCK_FILE"
chmod 666 "$LOCK_FILE" 2>/dev/null || true

if ! flock -n 200; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Sync already running. Exiting."
    exit 0
fi

# 2. Detect target user and load configuration
TARGET_USER="${SUDO_USER:-$USER}"
if [ "$TARGET_USER" = "root" ] || [ -z "$TARGET_USER" ]; then
    if id "mariofishy" >/dev/null 2>&1; then
        TARGET_USER="mariofishy"
    else
        TARGET_USER="$(awk -F: '$3 >= 1000 && $1 != "nobody" {print $1; exit}' /etc/passwd 2>/dev/null || echo "$USER")"
    fi
fi

TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6)"
TARGET_HOME="${TARGET_HOME:-/home/$TARGET_USER}"

CONFIG_FILE="${JELLYFIN_SORT_CONFIG:-$TARGET_HOME/.config/jellyfin-reel-sort.conf}"
if [ ! -f "$CONFIG_FILE" ] && [ -f "/etc/jellyfin-reel-sort.conf" ]; then
    CONFIG_FILE="/etc/jellyfin-reel-sort.conf"
fi

if [ -f "$CONFIG_FILE" ]; then
    export JELLYFIN_SORT_CONFIG="$CONFIG_FILE"
    set -a
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    set +a
fi

# 3. Environment defaults
REMOTE_NAME="${REMOTE_NAME:-put.io}"
DOWNLOADS_DIR="${DOWNLOADS_DIR:-$TARGET_HOME/Jellyfin/downloads/}"
LOG_FILE="${LOG_FILE:-/var/log/jellyfin-reel-sort.log}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SORTER_SCRIPT="$SCRIPT_DIR/sorter.py"
if [ ! -f "$SORTER_SCRIPT" ]; then
    SORTER_SCRIPT="${SORTER_PATH:-$(dirname "$0")/sorter.py}"
fi
PYTHON_BIN="${PYTHON_BIN:-python3}"

if [ -x "$TARGET_HOME/.local/share/jellyfin-reel-sort/venv/bin/python3" ] && [ "$PYTHON_BIN" = "python3" ]; then
    PYTHON_BIN="$TARGET_HOME/.local/share/jellyfin-reel-sort/venv/bin/python3"
fi

# Fall back to user directory if /var/log is not writable
if ! mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || ! touch "$LOG_FILE" 2>/dev/null; then
    LOG_FILE="$TARGET_HOME/Jellyfin/sync.log"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
fi

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg" >> "$LOG_FILE"
    if [ -t 1 ]; then
        echo "$msg"
    fi
}

# 4. Ingest new downloads from Put.io with Checkpointing & Resilience
log "=== Starting $REMOTE_NAME sync to $DOWNLOADS_DIR ==="
mkdir -p "$DOWNLOADS_DIR"

# Checkpointing & Resilience Flags:
# - Sequential transfer (--transfers 1): commits one file at a time; completed files act as checkpoints
# - Size ordering (--order-by size,asc): finishes smaller files first so they are immediately preserved
# - Pre-flight check (--check-first): fast-skips all completed files in memory before queueing
# - Multi-stream chunks (--multi-thread-streams 8): parallel chunk downloads for speed and stream stability
# - Deep retries (--retries 10, --low-level-retries 20): automatically recovers from network drops
SYNC_TRANSFERS="${SYNC_TRANSFERS:-1}"
SYNC_STREAMS="${SYNC_STREAMS:-8}"
SYNC_RETRIES="${SYNC_RETRIES:-10}"
SYNC_LOW_LEVEL_RETRIES="${SYNC_LOW_LEVEL_RETRIES:-20}"

# Core flags supported universally across all rclone versions
RCLONE_RESILIENCE_FLAGS=(
    --transfers "$SYNC_TRANSFERS"
    --retries "$SYNC_RETRIES"
    --retries-sleep 5s
    --low-level-retries "$SYNC_LOW_LEVEL_RETRIES"
    --timeout 15m
    --contimeout 60s
)

# Dynamically add advanced flags if supported by installed rclone version
RCLONE_HELP="$(rclone copy --help 2>&1 || true)"
if echo "$RCLONE_HELP" | grep -q -- '--order-by'; then
    RCLONE_RESILIENCE_FLAGS+=(--check-first --order-by "size,ascending")
fi
if echo "$RCLONE_HELP" | grep -q -- '--multi-thread-streams'; then
    RCLONE_RESILIENCE_FLAGS+=(--multi-thread-streams "$SYNC_STREAMS")
fi

if command -v rclone >/dev/null 2>&1; then
    if [ -t 1 ]; then
        rclone copy "$REMOTE_NAME:/" "$DOWNLOADS_DIR" \
            "${RCLONE_RESILIENCE_FLAGS[@]}" \
            --progress --log-file="$LOG_FILE"
    else
        rclone copy "$REMOTE_NAME:/" "$DOWNLOADS_DIR" \
            "${RCLONE_RESILIENCE_FLAGS[@]}" \
            --log-file="$LOG_FILE"
    fi
else
    log "Error: rclone not found in PATH. Skipping remote copy."
fi

# Ensure correct file ownership when run via sudo / root cron
if [ "$(id -u)" -eq 0 ] && id "$TARGET_USER" >/dev/null 2>&1; then
    chown -R "$TARGET_USER:$TARGET_USER" "$DOWNLOADS_DIR" 2>/dev/null || true
fi

# 5. Sort, hardlink, and refresh Jellyfin
log "=== Sorting and hardlinking media into Jellyfin ==="
if [ -t 1 ]; then
    "$PYTHON_BIN" "$SORTER_SCRIPT" 2>&1 | tee -a "$LOG_FILE"
else
    "$PYTHON_BIN" "$SORTER_SCRIPT" >> "$LOG_FILE" 2>&1
fi

log "=== Finished sync and sort pipeline ==="
