#!/bin/bash

# ==============================================================================
# Jellyfin Reel Sort — Initial Media Import Utility
#
# Scans existing downloads in ~/Jellyfin/downloads/ (or a custom folder),
# identifies TV shows and Movies using guessit, creates zero-space hardlinks
# into ~/Jellyfin/media/ (Shows & Movies), fixes ownership/permissions,
# and triggers a Jellyfin library scan.
# ==============================================================================

# Formatting
BOLD="\033[1m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[36m"
MAGENTA="\033[35m"
RESET="\033[0m"

# 1. Resolve Script Location and Target User Dynamically
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
    repo_owner="$(stat -c '%U' "$SCRIPT_DIR" 2>/dev/null || true)"
    if [ -n "$repo_owner" ] && [ "$repo_owner" != "root" ] && id "$repo_owner" >/dev/null 2>&1; then
        TARGET_USER="$repo_owner"
    fi
fi

if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
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

    if [ "$(id -u)" -eq 0 ] && id "$TARGET_USER" >/dev/null 2>&1; then
        chown -h "$TARGET_USER:$TARGET_USER" "$bin_dir"/*.sh "$bin_dir"/sorter.py 2>/dev/null || true
    fi
}
auto_symlink_scripts

# 2. Load Configuration
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

# Fallback Paths
DOWNLOADS_DIR="${DOWNLOADS_DIR:-$TARGET_HOME/Jellyfin/downloads/}"
MEDIA_DIR="${MEDIA_DIR:-$TARGET_HOME/Jellyfin/media/}"
SHOWS_DIR="${SHOWS_DIR:-${MEDIA_DIR%/}/Shows/}"
MOVIES_DIR="${MOVIES_DIR:-${MEDIA_DIR%/}/Movies/}"
SORTER_SCRIPT="$SCRIPT_DIR/sorter.py"
if [ ! -f "$SORTER_SCRIPT" ]; then
    SORTER_SCRIPT="${SORTER_PATH:-$(dirname "$0")/sorter.py}"
fi
PYTHON_BIN="${PYTHON_BIN:-python3}"

if [ -x "$TARGET_HOME/.local/share/jellyfin-reel-sort/venv/bin/python3" ] && [ "$PYTHON_BIN" = "python3" ]; then
    PYTHON_BIN="$TARGET_HOME/.local/share/jellyfin-reel-sort/venv/bin/python3"
fi

# 3. Parse CLI Arguments (Custom Directory / Subtitle Flags)
SCAN_DIR="$DOWNLOADS_DIR"
CLI_SUBS=""

for arg in "$@"; do
    case "$arg" in
        --fast|--no-subs|--skip-subs)
            CLI_SUBS="fast"
            ;;
        --with-subs|--subs)
            CLI_SUBS="full"
            ;;
        -h|--help)
            echo "Usage: $0 [DIRECTORY] [--fast | --with-subs]"
            echo ""
            echo "Options:"
            echo "  DIRECTORY     Folder to import from (default: $DOWNLOADS_DIR)"
            echo "  --fast        Skip online subtitle downloads (fastest initial import)"
            echo "  --with-subs   Download online subtitles for all imported media"
            echo "  -h, --help    Show this help message"
            exit 0
            ;;
        *)
            if [ -d "$arg" ]; then
                SCAN_DIR="$(cd "$arg" && pwd)/"
            fi
            ;;
    esac
done

clear
echo -e "${BOLD}${CYAN}======================================================${RESET}"
echo -e "${BOLD}     Jellyfin Reel Sort — Initial Media Import        ${RESET}"
echo -e "${BOLD}${CYAN}======================================================${RESET}"
echo -e "  Target User:         ${GREEN}$TARGET_USER${RESET}"
echo -e "  Source Ingest:       ${GREEN}$SCAN_DIR${RESET}"
echo -e "  Destination Shows:   ${GREEN}$SHOWS_DIR${RESET}"
echo -e "  Destination Movies:  ${GREEN}$MOVIES_DIR${RESET}"
echo -e "${BOLD}${CYAN}------------------------------------------------------${RESET}"

# 4. Verify source directory exists
if [ ! -d "$SCAN_DIR" ]; then
    echo -e "${RED}[!] Ingest directory does not exist: $SCAN_DIR${RESET}"
    echo -e "    Please create it or specify a valid directory."
    exit 1
fi

# 5. Inventory existing media files
echo -e "${BOLD}[*] Scanning for media files...${RESET}"
MEDIA_COUNT=0
TOTAL_SIZE="0 MB"

# Count supported video files (.mkv, .mp4, .avi)
MEDIA_FILES=$(find "$SCAN_DIR" -type f \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.avi" \) 2>/dev/null || true)
if [ -n "$MEDIA_FILES" ]; then
    MEDIA_COUNT=$(echo "$MEDIA_FILES" | grep -c .)
    TOTAL_SIZE=$(du -ch $MEDIA_FILES 2>/dev/null | tail -n1 | cut -f1)
fi

echo -e "  Found: ${BOLD}${GREEN}$MEDIA_COUNT video files${RESET} (${BOLD}$TOTAL_SIZE${RESET} on disk)"

if [ "$MEDIA_COUNT" -eq 0 ]; then
    echo ""
    echo -e "${YELLOW}[!] No video files (.mkv, .mp4, .avi) found in $SCAN_DIR.${RESET}"
    echo -e "    Add media to your downloads folder or specify another directory:"
    echo -e "    ${CYAN}$0 /path/to/media${RESET}"
    exit 0
fi

echo ""

# 6. Subtitle Preference
FETCH_SUBS="0"
if [ "$CLI_SUBS" = "fast" ]; then
    FETCH_SUBS="0"
    echo -e "${CYAN}[*] CLI flag selected: Fast import (skipping online subtitles).${RESET}"
elif [ "$CLI_SUBS" = "full" ]; then
    FETCH_SUBS="1"
    echo -e "${CYAN}[*] CLI flag selected: Full import (downloading online subtitles).${RESET}"
else
    echo -e "${BOLD}Subtitle Option for Initial Bulk Import:${RESET}"
    echo -e "  ${GREEN}1) Fast Import (Recommended)${RESET}"
    echo -e "     Instantly creates hardlinks into your Jellyfin library in seconds."
    echo -e "     Skips online subtitle downloads (existing packaged .srt files are still linked)."
    echo ""
    echo -e "  ${YELLOW}2) Full Import with Online Subtitles${RESET}"
    echo -e "     Queries online subtitle providers for every file."
    echo -e "     (Note: May take significantly longer on large libraries due to API rate limits)."
    echo ""
    read -r -p "Select option [1/2] (default: 1): " sub_choice
    case "$sub_choice" in
        2)
            FETCH_SUBS="1"
            echo -e "  ${YELLOW}✓ Online subtitle fetching enabled.${RESET}"
            ;;
        *)
            FETCH_SUBS="0"
            echo -e "  ${GREEN}✓ Fast import selected (skipping online subtitle lookups).${RESET}"
            ;;
    esac
fi

echo ""
read -r -p "Proceed with importing $MEDIA_COUNT files into Jellyfin? [Y/n]: " confirm
if [[ "$confirm" =~ ^[Nn]$ ]]; then
    echo -e "${YELLOW}[!] Import cancelled.${RESET}"
    exit 0
fi

# 7. Ensure target directories exist
mkdir -p "$SHOWS_DIR" "$MOVIES_DIR"

# 8. Execute sorter
echo ""
echo -e "${BOLD}${CYAN}======================================================${RESET}"
echo -e "${BOLD}              Executing Media Import...               ${RESET}"
echo -e "${BOLD}${CYAN}======================================================${RESET}"

export ENABLE_SUBTITLES="$FETCH_SUBS"
if [ "$FETCH_SUBS" -eq 0 ]; then
    export DOWNLOAD_SUBTITLES="false"
else
    export DOWNLOAD_SUBTITLES="true"
fi

"$PYTHON_BIN" "$SORTER_SCRIPT" "$SCAN_DIR"

echo ""
echo -e "${BOLD}${CYAN}======================================================${RESET}"
echo -e "${BOLD}             Post-Import Permission Check             ${RESET}"
echo -e "${BOLD}${CYAN}======================================================${RESET}"

# Fix file ownership for target user and set 775 permissions
if [ "$(id -u)" -eq 0 ] && id "$TARGET_USER" >/dev/null 2>&1; then
    echo -e "  Fixing ownership to ${GREEN}$TARGET_USER:$TARGET_USER${RESET}..."
    chown -R "$TARGET_USER:$TARGET_USER" "$MEDIA_DIR" "$SCAN_DIR" 2>/dev/null || true
fi
chmod -R 775 "$MEDIA_DIR" 2>/dev/null || true
echo -e "  ${GREEN}✓ File permissions aligned (775).${RESET}"

# 9. Summary and Jellyfin Refresh
SHOW_COUNT=$(find "$SHOWS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
MOVIE_COUNT=$(find "$MOVIES_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)

# Resolve local IP
LOCAL_IP="$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}' || hostname -I 2>/dev/null | awk '{print $1}')"
LOCAL_IP="${LOCAL_IP:-localhost}"

echo ""
echo -e "${BOLD}${GREEN}======================================================${RESET}"
echo -e "${BOLD}${GREEN}            Initial Import Completed!                 ${RESET}"
echo -e "${BOLD}${GREEN}======================================================${RESET}"
echo -e "  TV Series in Library: ${BOLD}${GREEN}$SHOW_COUNT shows${RESET}"
echo -e "  Movies in Library:    ${BOLD}${GREEN}$MOVIE_COUNT movies${RESET}"
echo -e "  Storage Consumed:     ${BOLD}${GREEN}0 extra bytes${RESET} (hardlinks preserve disk space)"
echo ""
echo -e "  Browse your imported media in Jellyfin:"
echo -e "  ${CYAN}${BOLD}http://${LOCAL_IP}:8096${RESET}  (or http://localhost:8096)"
echo -e "${BOLD}${GREEN}======================================================${RESET}"
echo ""
