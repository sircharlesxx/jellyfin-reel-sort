#!/bin/bash

# ==============================================================================
# Jellyfin Reel Sort — Main Cloud Ingest & Sort Pipeline
#
# Standardized Automated Pipeline:
#   1. Lock & Concurrency: Prevents overlapping runs via non-blocking flock.
#   2. User & Config: Automatically targets user & loads ~/.config.
#   3. Cloud Ingest: rclone copy from cloud remote to ~/Jellyfin/downloads/.
#   4. Permission Management: Fixes ownership for target user on root cron runs.
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

# 2. Resolve script location and target user dynamically
SOURCE_FILE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE_FILE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE_FILE")" && pwd)"
    SOURCE_FILE="$(readlink "$SOURCE_FILE")"
    [[ $SOURCE_FILE != /* ]] && SOURCE_FILE="$DIR/$SOURCE_FILE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE_FILE")" && pwd)"

TARGET_USER="${TARGET_USER:-$SUDO_USER}"
[ -z "$TARGET_USER" ] && [ "$USER" != "root" ] && TARGET_USER="$USER"

if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
    # 1. Discover owner from existing user configuration
    for conf in /home/*/.config/jellyfin-reel-sort.conf; do
        if [ -f "$conf" ]; then
            cand="$(basename "$(dirname "$(dirname "$conf")")")"
            if id "$cand" >/dev/null 2>&1; then
                TARGET_USER="$cand"
                break
            fi
        fi
    done
fi

if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
    # 2. Check repo/script owner
    repo_owner="$(stat -c '%U' "$SCRIPT_DIR" 2>/dev/null || true)"
    if [ -n "$repo_owner" ] && [ "$repo_owner" != "root" ] && id "$repo_owner" >/dev/null 2>&1; then
        TARGET_USER="$repo_owner"
    fi
fi

if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
    # 3. First non-system user (UID >= 1000)
    TARGET_USER="$(awk -F: '$3 >= 1000 && $1 != "nobody" {print $1; exit}' /etc/passwd 2>/dev/null || echo "$USER")"
fi

TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6)"
TARGET_HOME="${TARGET_HOME:-/home/$TARGET_USER}"

# Automatically ensure CLI helper scripts in ~/.local/bin/ are symlinked to this repository
auto_symlink_scripts() {
    local bin_dir="$TARGET_HOME/.local/bin"
    [ "$SCRIPT_DIR" = "$bin_dir" ] && return 0
    mkdir -p "$bin_dir" 2>/dev/null || return 0

    local scripts=("putsync.sh" "get_movie.sh" "sorter.py" "delete.sh" "initial-import.sh" "jellyfin-docker-setup.sh")
    for s in "${scripts[@]}"; do
        local src="$SCRIPT_DIR/$s"
        local dst="$bin_dir/$s"
        if [ -f "$src" ]; then
            if [ ! -L "$dst" ] || [ "$(readlink -f "$dst" 2>/dev/null)" != "$src" ]; then
                ln -sf "$src" "$dst" 2>/dev/null || true
            fi
        fi
    done

    # Convenience aliases
    [ -f "$SCRIPT_DIR/get_movie.sh" ] && ln -sf "$SCRIPT_DIR/get_movie.sh" "$bin_dir/get_media.sh" 2>/dev/null || true
    [ -f "$SCRIPT_DIR/initial-import.sh" ] && ln -sf "$SCRIPT_DIR/initial-import.sh" "$bin_dir/import_media.sh" 2>/dev/null || true
    [ -f "$SCRIPT_DIR/jellyfin-docker-setup.sh" ] && ln -sf "$SCRIPT_DIR/jellyfin-docker-setup.sh" "$bin_dir/docker-reinstall.sh" 2>/dev/null || true

    # Fix ownership if executed as root so target user owns the symlinks
    if [ "$(id -u)" -eq 0 ] && id "$TARGET_USER" >/dev/null 2>&1; then
        chown -h "$TARGET_USER:$TARGET_USER" "$bin_dir"/*.sh "$bin_dir"/sorter.py 2>/dev/null || true
    fi
}
auto_symlink_scripts

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

# 4. Network Warm-Up & Thermal Cool-Off (Cellular / 5G Optimization)
# Runs a quick 5-second download to trigger carrier aggregation, logs the speed, 
# then sleeps for 2 minutes to let the modem cool down before the heavy sync begins.
log "=== Running 5-second network warm-up / speed test ==="
SPEED_BPS=$(curl -o /dev/null -s -w "%{speed_download}" -m 5 http://speedtest.chicago.linode.com/100MB-chicago.bin || echo "0")
SPEED_MBPS=$(awk -v bps="$SPEED_BPS" 'BEGIN { printf "%.2f", (bps * 8) / 1000000 }')
log "Warm-up speed: ${SPEED_MBPS} Mbps"

log "=== Cooling off modem for 2 minutes to prevent thermal throttling ==="
sleep 120

# 5. Ingest new downloads from cloud with Checkpointing & Resilience
log "=== Starting $REMOTE_NAME sync to $DOWNLOADS_DIR ==="
mkdir -p "$DOWNLOADS_DIR"

# Checkpointing & Resilience Flags:
# - Sequential transfer (--transfers 1): Commits exactly 1 file at a time. Once a file finishes, 
#   it is permanently locked in. If the connection drops, it resumes from the next file (Checkpointing).
# - Size ordering (--order-by size,asc): Finishes smaller files first so they are immediately preserved.
# - Pre-flight check (--check-first): Fast-skips all completed files in memory before queueing.
# - Multi-stream chunks (--multi-thread-streams 8): Utilizes concurrent HTTP Range requests to open 
#   8 parallel streams per file, forcing carriers to allocate maximum bandwidth (saturates gigabit/5G).
# - Deep retries (--retries 10, --low-level-retries 20): Automatically recovers from network drops.
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
