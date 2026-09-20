#!/bin/bash

# ==============================================================================
# Jellyfin Reel Sort — Docker Clean Reinstall & Setup Tool
# Assumes Jellyfin is not installed or corrupted and sets up:
#   1. Clean container removal & database reset
#   2. Hardlink-compatible directory structure on the same filesystem
#   3. Correct UID/GID ownership and 775 permissions
#   4. Hardware transcoding pass-through (/dev/dri) if available
#   5. Official Jellyfin Docker container with persistent volumes
#   6. Automated config sync with jellyfin-reel-sort
# ==============================================================================

set -e

# Formatting
BOLD="\033[1m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[36m"
RESET="\033[0m"

# Require root/sudo to manage Docker and permissions
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${YELLOW}[!] Root privileges required to configure Docker. Elevating with sudo...${RESET}"
    exec sudo bash "$0" "$@"
fi

# Detect actual target user (even when running via sudo)
TARGET_USER="${SUDO_USER:-$USER}"
if [ "$TARGET_USER" = "root" ]; then
    # If invoked directly as root, look for real non-root users in /home
    for h in /home/*; do
        if [ -d "$h" ]; then
            u="$(basename "$h")"
            if id "$u" >/dev/null 2>&1; then
                TARGET_USER="$u"
                break
            fi
        fi
    done
fi

TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6)"
TARGET_HOME="${TARGET_HOME:-/home/$TARGET_USER}"
TARGET_UID="$(id -u "$TARGET_USER" 2>/dev/null || echo 1000)"
TARGET_GID="$(id -g "$TARGET_USER" 2>/dev/null || echo 1000)"

clear
echo -e "${BOLD}${CYAN}======================================================${RESET}"
echo -e "${BOLD}     Jellyfin Reel Sort — Docker Clean Reinstall      ${RESET}"
echo -e "${BOLD}${CYAN}======================================================${RESET}"
echo -e "  Target User:     ${GREEN}$TARGET_USER${RESET} (UID: $TARGET_UID, GID: $TARGET_GID)"
echo -e "  User Home:       ${GREEN}$TARGET_HOME${RESET}"
echo -e "${BOLD}${CYAN}------------------------------------------------------${RESET}"
echo ""

# 1. Verify Docker is available
if ! command -v docker >/dev/null 2>&1; then
    echo -e "${YELLOW}[!] Docker not found. Attempting to install Docker...${RESET}"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y docker.io
    elif command -v synogroup >/dev/null 2>&1; then
        echo -e "${RED}[!] Please install the 'Container Manager' (Docker) package in Synology Package Center first.${RESET}"
        exit 1
    else
        echo -e "${RED}[!] Docker is required. Please install Docker and re-run this script.${RESET}"
        exit 1
    fi
fi

# Ensure docker service is running
if command -v systemctl >/dev/null 2>&1; then
    systemctl start docker 2>/dev/null || true
fi

# 2. Base directory configuration (all on single filesystem to guarantee hardlinks work)
JELLYFIN_BASE="$TARGET_HOME/Jellyfin"
DOWNLOADS_DIR="$JELLYFIN_BASE/downloads"
MEDIA_DIR="$JELLYFIN_BASE/media"
SHOWS_DIR="$MEDIA_DIR/Shows"
MOVIES_DIR="$MEDIA_DIR/Movies"
CONFIG_DIR="$JELLYFIN_BASE/config"
CACHE_DIR="$JELLYFIN_BASE/cache"

echo -e "${BOLD}[1/5] Removing existing Jellyfin container...${RESET}"
if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^jellyfin$"; then
    echo -e "  Stopping and removing old 'jellyfin' container..."
    docker stop jellyfin >/dev/null 2>&1 || true
    docker rm -f jellyfin >/dev/null 2>&1 || true
    echo -e "  ${GREEN}✓ Old container removed.${RESET}"
else
    echo -e "  ${CYAN}✓ No existing container named 'jellyfin' found.${RESET}"
fi

echo ""
echo -e "${BOLD}[2/5] Resetting database and cache...${RESET}"
echo -e "  Do you want to completely erase old/stale Jellyfin databases and metadata?"
echo -e "  ${YELLOW}(Note: Your video files in $MEDIA_DIR will NOT be deleted).${RESET}"
read -r -p "  Wipe database/cache for 100% fresh start? [Y/n]: " wipe_choice

if [[ ! "$wipe_choice" =~ ^[Nn]$ ]]; then
    rm -rf "$CONFIG_DIR" "$CACHE_DIR"
    echo -e "  ${GREEN}✓ Old Jellyfin database and cache wiped cleanly.${RESET}"
else
    echo -e "  ${CYAN}✓ Keeping existing config directory.${RESET}"
fi

echo ""
echo -e "${BOLD}[3/5] Setting up hardlink-compatible directory structure...${RESET}"
mkdir -p "$DOWNLOADS_DIR"
mkdir -p "$SHOWS_DIR"
mkdir -p "$MOVIES_DIR"
mkdir -p "$CONFIG_DIR"
mkdir -p "$CACHE_DIR"

# Ensure all directories are owned by target user with group r/w access
chown -R "$TARGET_UID:$TARGET_GID" "$JELLYFIN_BASE"
chmod -R 775 "$JELLYFIN_BASE"
echo -e "  ${GREEN}✓ Directories verified:${RESET}"
echo -e "    - Downloads: $DOWNLOADS_DIR"
echo -e "    - TV Shows:  $SHOWS_DIR"
echo -e "    - Movies:    $MOVIES_DIR"
echo -e "    - Config:    $CONFIG_DIR"
echo -e "    - Cache:     $CACHE_DIR"

echo ""
echo -e "${BOLD}[4/5] Pulling and launching official Jellyfin container...${RESET}"

# Check for hardware acceleration device (/dev/dri)
DRI_FLAG=()
if [ -d "/dev/dri" ]; then
    echo -e "  ${GREEN}✓ Intel/AMD GPU render device found (/dev/dri). Enabling hardware transcoding.${RESET}"
    DRI_FLAG=(--device /dev/dri:/dev/dri)
fi

# Detect system timezone
TZ_VAL="$(cat /etc/timezone 2>/dev/null || true)"
if [ -z "$TZ_VAL" ] && [ -L /etc/localtime ]; then
    TZ_VAL="$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')"
fi
TZ_VAL="${TZ_VAL:-UTC}"

echo -e "  Pulling 'jellyfin/jellyfin:latest' image..."
docker pull jellyfin/jellyfin:latest

# Run container with volume mapping matching the user's hardlinks
docker run -d \
    --name jellyfin \
    --restart unless-stopped \
    --user "$TARGET_UID:$TARGET_GID" \
    --net=bridge \
    -p 8096:8096 \
    -v "$CONFIG_DIR:/config" \
    -v "$CACHE_DIR:/cache" \
    -v "$MEDIA_DIR:/media" \
    -e PUID="$TARGET_UID" \
    -e PGID="$TARGET_GID" \
    -e TZ="$TZ_VAL" \
    "${DRI_FLAG[@]}" \
    jellyfin/jellyfin:latest

echo -e "  ${GREEN}✓ Jellyfin container started successfully!${RESET}"

echo ""
echo -e "${BOLD}[5/5] Aligning jellyfin-reel-sort configuration...${RESET}"
USER_CONFIG="$TARGET_HOME/.config/jellyfin-reel-sort.conf"
mkdir -p "$(dirname "$USER_CONFIG")"

if [ -f "$USER_CONFIG" ]; then
    sed -i "s|^DOWNLOADS_DIR=.*|DOWNLOADS_DIR=\"$DOWNLOADS_DIR/\"|" "$USER_CONFIG"
    sed -i "s|^MEDIA_DIR=.*|MEDIA_DIR=\"$MEDIA_DIR/\"|" "$USER_CONFIG"
    sed -i "s|^SHOWS_DIR=.*|SHOWS_DIR=\"$SHOWS_DIR/\"|" "$USER_CONFIG"
    sed -i "s|^MOVIES_DIR=.*|MOVIES_DIR=\"$MOVIES_DIR/\"|" "$USER_CONFIG"
    sed -i "s|^CLEANUP_MODE=.*|CLEANUP_MODE=\"none\"|" "$USER_CONFIG"
    sed -i "s|^JELLYFIN_URL=.*|JELLYFIN_URL=\"http://localhost:8096\"|" "$USER_CONFIG"
else
    cat <<EOF > "$USER_CONFIG"
DOWNLOADS_DIR="$DOWNLOADS_DIR/"
MEDIA_DIR="$MEDIA_DIR/"
SHOWS_DIR="$SHOWS_DIR/"
MOVIES_DIR="$MOVIES_DIR/"
CLEANUP_MODE="none"
DOWNLOAD_SUBTITLES="true"
SUBTITLE_LANGUAGES="en"
REMOTE_NAME="put.io"
JELLYFIN_URL="http://localhost:8096"
JELLYFIN_API_KEY=""
SORTER_PATH="$(dirname "$0")/sorter.py"
EOF
fi
chown "$TARGET_UID:$TARGET_GID" "$USER_CONFIG"
echo -e "  ${GREEN}✓ Configuration saved to $USER_CONFIG${RESET}"

# Find local IP
LOCAL_IP="$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}' || hostname -I 2>/dev/null | awk '{print $1}')"
LOCAL_IP="${LOCAL_IP:-localhost}"

echo ""
echo -e "${BOLD}${GREEN}======================================================${RESET}"
echo -e "${BOLD}${GREEN}     Jellyfin Has Been Reinstalled Successfully!      ${RESET}"
echo -e "${BOLD}${GREEN}======================================================${RESET}"
echo -e "  Access your fresh Jellyfin server in your browser at:"
echo -e "  ${CYAN}${BOLD}http://${LOCAL_IP}:8096${RESET}  (or http://localhost:8096)"
echo ""
echo -e "${BOLD}Setup Wizard & Next Steps:${RESET}"
echo -e "  1. Complete the initial user and password setup."
echo -e "  2. When prompted to ${BOLD}Add Media Libraries${RESET}:"
echo -e "     - For ${BOLD}TV Shows${RESET}: Add folder ${GREEN}/media/Shows${RESET}"
echo -e "     - For ${BOLD}Movies${RESET}:   Add folder ${GREEN}/media/Movies${RESET}"
echo -e "     ${YELLOW}(Notice: In the Jellyfin web setup, select /media/... as shown above)${RESET}"
echo -e "  3. To enable auto-refresh on downloads/deletes:"
echo -e "     - Go to ${BOLD}Dashboard → API Keys${RESET}, create an API key, and paste it into:"
echo -e "       ${CYAN}$USER_CONFIG${RESET}"
echo -e "  4. Run a test sync to verify:"
echo -e "       ${CYAN}$TARGET_HOME/jellyfin-reel-sort/putsync.sh${RESET}"
echo -e "  5. Ensure background sync is active in root crontab (${BOLD}sudo crontab -e${RESET}):"
echo -e "       ${CYAN}*/5 * * * * $TARGET_HOME/jellyfin-reel-sort/putsync.sh >/dev/null 2>&1${RESET}"
echo -e "${BOLD}${GREEN}======================================================${RESET}"
echo ""
