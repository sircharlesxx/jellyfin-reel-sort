#!/bin/bash
set -e

echo "================================================"
echo "    jellyfin-reel-sort Installer & Setup"
echo "================================================"
echo ""

# Check python3
if ! command -v python3 >/dev/null 2>&1; then
    echo "[-] Error: python3 is required but not installed." >&2
    if command -v apt-get >/dev/null 2>&1; then
        echo "    Run: sudo apt-get update && sudo apt-get install -y python3 python3-pip python3-venv"
    fi
    exit 1
fi

# Define scripts/environment destination paths early
SOURCE_FILE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE_FILE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE_FILE")" && pwd)"
    SOURCE_FILE="$(readlink "$SOURCE_FILE")"
    [[ $SOURCE_FILE != /* ]] && SOURCE_FILE="$DIR/$SOURCE_FILE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE_FILE")" && pwd)"

# Detect actual target user dynamically
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
    for h in /home/*; do
        if [ -d "$h" ]; then
            u="$(basename "$h")"
            if id "$u" >/dev/null 2>&1 && [ "$u" != "lost+found" ]; then
                TARGET_USER="$u"
                break
            fi
        fi
    done
fi

if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
    TARGET_USER="$(awk -F: '$3 >= 1000 && $1 != "nobody" {print $1; exit}' /etc/passwd 2>/dev/null || echo "$USER")"
fi

TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6)"
TARGET_HOME="${TARGET_HOME:-/home/$TARGET_USER}"
TARGET_UID="$(id -u "$TARGET_USER" 2>/dev/null || echo 1000)"
TARGET_GID="$(id -g "$TARGET_USER" 2>/dev/null || echo 1000)"

DEFAULT_INSTALL_DIR="$TARGET_HOME/.local/bin"
VENV_DIR="$TARGET_HOME/.local/share/jellyfin-reel-sort/venv"

# Helper for sudo commands
run_sudo() {
    if [ "$EUID" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        echo "[-] Sudo is required for this operation: $*" >&2
        return 1
    fi
}

# --- Robust Dependency Installer (Handles PEP 668 externally-managed environments, apt, and venv) ---
install_python_dependencies() {
    echo "[+] Checking Python dependencies (guessit, subliminal)..."

    # Test if both dependencies already work with system/user python3
    if sudo -u "$TARGET_USER" python3 -c "import guessit, subliminal" >/dev/null 2>&1 || python3 -c "import guessit, subliminal" >/dev/null 2>&1; then
        echo "[+] All required dependencies are already available in python3."
        PYTHON_BIN="$(command -v python3)"
        return 0
    fi

    # 1. Check if apt package manager is available (Ubuntu/Debian)
    if command -v apt-get >/dev/null 2>&1; then
        echo "[!] Debian/Ubuntu-based system detected with externally-managed Python."
        echo "    Attempting to install system packages via apt..."
        
        run_sudo apt-get update -y || true
        run_sudo apt-get install -y python3-pip python3-venv python3-guessit python3-subliminal || true

        if python3 -c "import guessit, subliminal" >/dev/null 2>&1; then
            echo "[+] Dependencies successfully resolved via apt."
            PYTHON_BIN="$(command -v python3)"
            return 0
        fi
    fi

    # 2. Try pip install with --break-system-packages or --user
    echo "[*] Trying pip with user flags..."
    if command -v pip3 >/dev/null 2>&1 || command -v pip >/dev/null 2>&1; then
        PIP_CMD="$(command -v pip3 || command -v pip)"
        if sudo -u "$TARGET_USER" $PIP_CMD install --user --break-system-packages -r "$SCRIPT_DIR/requirements.txt" >/dev/null 2>&1 || $PIP_CMD install --user --break-system-packages -r "$SCRIPT_DIR/requirements.txt" >/dev/null 2>&1; then
            echo "[+] Dependencies installed via pip (--break-system-packages)."
            PYTHON_BIN="$(command -v python3)"
            return 0
        elif sudo -u "$TARGET_USER" $PIP_CMD install --user -r "$SCRIPT_DIR/requirements.txt" >/dev/null 2>&1 || $PIP_CMD install --user -r "$SCRIPT_DIR/requirements.txt" >/dev/null 2>&1; then
            echo "[+] Dependencies installed via pip (--user)."
            PYTHON_BIN="$(command -v python3)"
            return 0
        fi
    fi

    # 3. Create a clean dedicated virtual environment (the official PEP 668 standard)
    echo "[*] Externally managed environment detected. Creating dedicated virtual environment..."
    run_sudo mkdir -p "$(dirname "$VENV_DIR")"
    run_sudo chown -R "$TARGET_UID:$TARGET_GID" "$(dirname "$VENV_DIR")"
    
    if ! sudo -u "$TARGET_USER" python3 -m venv "$VENV_DIR" >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            echo "[!] python3-venv package is required. Installing via apt..."
            run_sudo apt-get install -y python3-venv
            sudo -u "$TARGET_USER" python3 -m venv "$VENV_DIR"
        else
            echo "[-] Error: Failed to create python3 virtual environment at $VENV_DIR." >&2
            exit 1
        fi
    fi

    echo "[+] Installing packages into dedicated venv ($VENV_DIR)..."
    sudo -u "$TARGET_USER" "$VENV_DIR/bin/pip" install --upgrade pip >/dev/null 2>&1 || true
    sudo -u "$TARGET_USER" "$VENV_DIR/bin/pip" install -r "$SCRIPT_DIR/requirements.txt"
    PYTHON_BIN="$VENV_DIR/bin/python3"
    echo "[+] Virtual environment configured successfully."
}

install_python_dependencies

# Auto-detect existing rclone remotes
RCLONE_REMOTES=()
DEFAULT_REMOTE="cloud"

if command -v rclone >/dev/null 2>&1; then
    echo "[+] Checking rclone remotes..."
    while IFS= read -r rem; do
        clean_rem="${rem%:}"
        if [ -n "$clean_rem" ]; then
            RCLONE_REMOTES+=("$clean_rem")
        fi
    done < <(rclone listremotes 2>/dev/null || true)

    if [ ${#RCLONE_REMOTES[@]} -gt 0 ]; then
        echo "    Detected configured rclone remotes: ${RCLONE_REMOTES[*]}"
        DEFAULT_REMOTE="${RCLONE_REMOTES[0]}"
    fi
else
    echo "[!] Warning: 'rclone' command not found. You will need rclone to use cloud syncing."
    if command -v apt-get >/dev/null 2>&1; then
        echo "    (You can install it with: sudo apt install rclone)"
    fi
fi
echo ""

prompt_with_default() {
    local prompt="$1"
    local default_val="$2"
    local result=""
    if [ -t 0 ]; then
        read -r -p "$prompt [$default_val]: " result
    else
        read -r result || true
    fi
    echo "${result:-$default_val}"
}

# Auto-detect sensible default paths for downloads & media if they exist
DETECTED_DOWNLOADS=""
for cand in "$TARGET_HOME/Jellyfin/downloads" "$TARGET_HOME/downloads" "$TARGET_HOME/Downloads" "/volume1/home/$TARGET_USER/Jellyfin/downloads" "/volume1/downloads" "/media/downloads"; do
    if [ -d "$cand" ]; then
        DETECTED_DOWNLOADS="$cand"
        break
    fi
done
DEFAULT_DOWNLOADS="${DETECTED_DOWNLOADS:-$TARGET_HOME/Jellyfin/downloads}"

DETECTED_MEDIA=""
for cand in "$TARGET_HOME/Jellyfin/media" "$TARGET_HOME/media" "$TARGET_HOME/Media" "/volume1/home/$TARGET_USER/Jellyfin/media" "/volume1/media" "/volume1/video" "/media"; do
    if [ -d "$cand" ]; then
        DETECTED_MEDIA="$cand"
        break
    fi
done
DEFAULT_MEDIA="${DETECTED_MEDIA:-$TARGET_HOME/Jellyfin/media}"

echo "------------------------------------------------"
echo " Configuration Setup"
echo " (Press ENTER to accept auto-detected or default values)"
echo "------------------------------------------------"

INPUT_DOWNLOADS=$(prompt_with_default "Enter Downloads / Ingest Staging Directory" "$DEFAULT_DOWNLOADS")
DOWNLOADS_DIR="${INPUT_DOWNLOADS/#\~/$TARGET_HOME}"

INPUT_MEDIA=$(prompt_with_default "Enter Jellyfin Media Root Directory" "$DEFAULT_MEDIA")
MEDIA_DIR="${INPUT_MEDIA/#\~/$TARGET_HOME}"

DEFAULT_CLEANUP="none"
echo ""
echo "Source cleanup mode after linking (options: 'none' [safe for seeding], 'delete' [remove source], 'move' [archive source]):"
INPUT_CLEANUP=$(prompt_with_default "Enter cleanup mode (none/delete/move)" "$DEFAULT_CLEANUP")
CLEANUP_MODE="$INPUT_CLEANUP"

ARCHIVE_DIR=""
if [ "$CLEANUP_MODE" = "move" ]; then
    DEFAULT_ARCHIVE="$TARGET_HOME/Jellyfin/processed"
    INPUT_ARCHIVE=$(prompt_with_default "Enter archive directory for processed files" "$DEFAULT_ARCHIVE")
    ARCHIVE_DIR="${INPUT_ARCHIVE/#\~/$TARGET_HOME}"
fi

DEFAULT_SUBS="true"
echo ""
INPUT_SUBS=$(prompt_with_default "Download subtitles automatically? (true/false)" "$DEFAULT_SUBS")
DOWNLOAD_SUBTITLES="$INPUT_SUBS"

DEFAULT_LANGS="en"
SUBTITLE_LANGUAGES="en"
if [ "$DOWNLOAD_SUBTITLES" = "true" ] || [ "$DOWNLOAD_SUBTITLES" = "1" ] || [ "$DOWNLOAD_SUBTITLES" = "yes" ]; then
    INPUT_LANGS=$(prompt_with_default "Enter subtitle language code(s), comma-separated (e.g. en, es, fr)" "$DEFAULT_LANGS")
    SUBTITLE_LANGUAGES="$INPUT_LANGS"
fi

echo ""
INPUT_REMOTE=$(prompt_with_default "Enter rclone remote name for cloud sync (detected: $DEFAULT_REMOTE)" "$DEFAULT_REMOTE")
REMOTE_NAME="$INPUT_REMOTE"

echo ""
DEFAULT_JF_URL=""
if command -v curl >/dev/null 2>&1; then
    if curl -s --max-time 1 "http://127.0.0.1:8096/System/Info/Public" 2>/dev/null | grep -qi "Jellyfin"; then
        DEFAULT_JF_URL="http://127.0.0.1:8096"
    fi
fi
if [ -z "$DEFAULT_JF_URL" ] && command -v docker >/dev/null 2>&1; then
    JF_PORT=$(docker ps --format '{{.Image}} {{.Ports}}' 2>/dev/null | grep -i "jellyfin" | grep -o '0\.0\.0\.0:[0-9]*' | head -n1 | cut -d: -f2)
    if [ -n "$JF_PORT" ]; then
        DEFAULT_JF_URL="http://127.0.0.1:$JF_PORT"
    fi
fi

if [ -n "$DEFAULT_JF_URL" ]; then
    echo "  [✓] Detected active Jellyfin server on $DEFAULT_JF_URL"
    INPUT_JF_KEY=$(prompt_with_default "Enter Jellyfin API Key for automatic library scan (leave blank to skip)" "")
    JELLYFIN_API_KEY="$INPUT_JF_KEY"
else
    INPUT_JF_KEY=$(prompt_with_default "Enter Jellyfin API Key for automatic library scan (leave blank to skip)" "")
    JELLYFIN_API_KEY="$INPUT_JF_KEY"
fi

INPUT_INSTALL_DIR=$(prompt_with_default "Enter directory to install executable scripts" "$DEFAULT_INSTALL_DIR")
INSTALL_DIR="${INPUT_INSTALL_DIR/#\~/$TARGET_HOME}"

DEFAULT_CONF="$TARGET_HOME/.config/jellyfin-reel-sort.conf"
INPUT_CONF=$(prompt_with_default "Enter path for configuration file" "$DEFAULT_CONF")
CONF_PATH="${INPUT_CONF/#\~/$TARGET_HOME}"

echo ""
echo "[+] Target settings confirmed:"
echo "  - Target User:        $TARGET_USER (UID $TARGET_UID)"
echo "  - Target Home:        $TARGET_HOME"
echo "  - Ingest Downloads:   $DOWNLOADS_DIR"
echo "  - Media Library:      $MEDIA_DIR"
echo "  - Cleanup Mode:       $CLEANUP_MODE"
[ -n "$ARCHIVE_DIR" ] && echo "  - Archive Folder:     $ARCHIVE_DIR"
echo "  - Subtitle Downloads: $DOWNLOAD_SUBTITLES ($SUBTITLE_LANGUAGES)"
echo "  - Python Executable:  $PYTHON_BIN"
echo "  - Rclone Remote:      $REMOTE_NAME"
[ -n "$DEFAULT_JF_URL" ] && echo "  - Jellyfin Server:    $DEFAULT_JF_URL"
[ -n "$JELLYFIN_API_KEY" ] && echo "  - Jellyfin Auto-Scan: Enabled (API key set)"
echo "  - Install Scripts:    $INSTALL_DIR"
echo "  - Config File:        $CONF_PATH"
echo ""

echo "[+] Preparing directories..."
run_sudo mkdir -p "$DOWNLOADS_DIR"
run_sudo mkdir -p "$MEDIA_DIR/Shows"
run_sudo mkdir -p "$MEDIA_DIR/Movies"
[ -n "$ARCHIVE_DIR" ] && run_sudo mkdir -p "$ARCHIVE_DIR"
run_sudo mkdir -p "$INSTALL_DIR"
run_sudo mkdir -p "$(dirname "$CONF_PATH")"
run_sudo chown -R "$TARGET_UID:$TARGET_GID" "$MEDIA_DIR" "$DOWNLOADS_DIR" "$(dirname "$CONF_PATH")" 2>/dev/null || true

# Write configuration
echo "[+] Writing configuration to $CONF_PATH..."
run_sudo bash -c "cat << CONF_EOF > \"$CONF_PATH\"
# jellyfin-reel-sort configuration
DOWNLOADS_DIR=\"$DOWNLOADS_DIR/\"
MEDIA_DIR=\"$MEDIA_DIR/\"
SHOWS_DIR=\"$MEDIA_DIR/Shows/\"
MOVIES_DIR=\"$MEDIA_DIR/Movies/\"
CLEANUP_MODE=\"$CLEANUP_MODE\"
ARCHIVE_DIR=\"$ARCHIVE_DIR\"
DOWNLOAD_SUBTITLES=\"$DOWNLOAD_SUBTITLES\"
SUBTITLE_LANGUAGES=\"$SUBTITLE_LANGUAGES\"
PYTHON_BIN=\"$PYTHON_BIN\"
REMOTE_NAME=\"$REMOTE_NAME\"
JELLYFIN_URL=\"$DEFAULT_JF_URL\"
JELLYFIN_API_KEY=\"$JELLYFIN_API_KEY\"
LOG_FILE=\"$TARGET_HOME/.local/state/jellyfin-reel-sort/sync.log\"
LOCK_FILE=\"/tmp/jellyfin_reel_sort.lock\"
SORTER_PATH=\"$INSTALL_DIR/sorter.py\"
SYNC_TRANSFERS=\"1\"
SYNC_STREAMS=\"8\"
CONF_EOF"
run_sudo chown "$TARGET_UID:$TARGET_GID" "$CONF_PATH"

# Auto-symlink scripts instead of copying them (matches architectural pattern)
echo "[+] Symlinking scripts into $INSTALL_DIR..."
scripts=("putsync.sh" "get_movie.sh" "sorter.py" "delete.sh" "initial-import.sh" "jellyfin-docker-setup.sh")
for s in "${scripts[@]}"; do
    if [ -f "$SCRIPT_DIR/$s" ]; then
        run_sudo ln -sf "$SCRIPT_DIR/$s" "$INSTALL_DIR/$s"
    fi
done

# Setup convenience symlinks
run_sudo ln -sf "$INSTALL_DIR/get_movie.sh" "$INSTALL_DIR/get_media.sh" 2>/dev/null || true
run_sudo ln -sf "$INSTALL_DIR/initial-import.sh" "$INSTALL_DIR/import_media.sh" 2>/dev/null || true
run_sudo ln -sf "$INSTALL_DIR/jellyfin-docker-setup.sh" "$INSTALL_DIR/docker-reinstall.sh" 2>/dev/null || true

run_sudo chmod +x "$SCRIPT_DIR/sorter.py"
run_sudo chmod +x "$SCRIPT_DIR"/*.sh 2>/dev/null || true
run_sudo chown -h "$TARGET_UID:$TARGET_GID" "$INSTALL_DIR"/*.sh "$INSTALL_DIR"/sorter.py 2>/dev/null || true

# Ensure user state/log directory exists
run_sudo mkdir -p "$TARGET_HOME/.local/state/jellyfin-reel-sort"
run_sudo chown -R "$TARGET_UID:$TARGET_GID" "$TARGET_HOME/.local/state/jellyfin-reel-sort" 2>/dev/null || true

echo ""
echo "================================================"
echo "    Installation Complete!"
echo "================================================"
echo "Scripts symlinked:"
echo "  - Sync & Sort Orchestrator:  $INSTALL_DIR/putsync.sh"
echo "  - Single Media Downloader:   $INSTALL_DIR/get_movie.sh (or get_media.sh)"
echo "  - Initial Bulk Importer:     $INSTALL_DIR/initial-import.sh (or import_media.sh)"
echo "  - Interactive Media Deleter: $INSTALL_DIR/delete.sh"
echo "  - Docker Reinstall & Setup:  $INSTALL_DIR/jellyfin-docker-setup.sh"
echo "  - Hardlink Sorter:           $INSTALL_DIR/sorter.py"
echo "  - Python Binary:             $PYTHON_BIN"
echo "  - Rclone Remote Name:        $REMOTE_NAME"
echo "Configuration file:            $CONF_PATH"
echo ""
echo "To run manually:"
echo "  $INSTALL_DIR/putsync.sh"
echo ""
echo "To automate with cron (every 5 mins), add to crontab:"
echo "  */5 * * * * $INSTALL_DIR/putsync.sh >/dev/null 2>&1"
echo "================================================"
