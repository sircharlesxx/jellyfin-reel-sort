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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_INSTALL_DIR="$HOME/.local/bin"
VENV_DIR="$HOME/.local/share/jellyfin-reel-sort/venv"

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
    if python3 -c "import guessit, subliminal" >/dev/null 2>&1; then
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
        if $PIP_CMD install --user --break-system-packages -r "$SCRIPT_DIR/requirements.txt" >/dev/null 2>&1; then
            echo "[+] Dependencies installed via pip (--break-system-packages)."
            PYTHON_BIN="$(command -v python3)"
            return 0
        elif $PIP_CMD install --user -r "$SCRIPT_DIR/requirements.txt" >/dev/null 2>&1; then
            echo "[+] Dependencies installed via pip (--user)."
            PYTHON_BIN="$(command -v python3)"
            return 0
        fi
    fi

    # 3. Create a clean dedicated virtual environment (the official PEP 668 standard)
    echo "[*] Externally managed environment detected. Creating dedicated virtual environment..."
    mkdir -p "$(dirname "$VENV_DIR")"
    if ! python3 -m venv "$VENV_DIR" >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            echo "[!] python3-venv package is required. Installing via apt..."
            run_sudo apt-get install -y python3-venv
            python3 -m venv "$VENV_DIR"
        else
            echo "[-] Error: Failed to create python3 virtual environment at $VENV_DIR." >&2
            exit 1
        fi
    fi

    echo "[+] Installing packages into dedicated venv ($VENV_DIR)..."
    "$VENV_DIR/bin/pip" install --upgrade pip >/dev/null 2>&1 || true
    "$VENV_DIR/bin/pip" install -r "$SCRIPT_DIR/requirements.txt"
    PYTHON_BIN="$VENV_DIR/bin/python3"
    echo "[+] Virtual environment configured successfully."
}

install_python_dependencies

# Auto-detect existing rclone remotes
RCLONE_REMOTES=()
DEFAULT_REMOTE="put.io"

if command -v rclone >/dev/null 2>&1; then
    echo "[+] Checking rclone remotes..."
    # rclone listremotes outputs remotes with trailing colon (e.g. 'put.io:', 'gdrive:')
    while IFS= read -r rem; do
        clean_rem="${rem%:}"
        if [ -n "$clean_rem" ]; then
            RCLONE_REMOTES+=("$clean_rem")
        fi
    done < <(rclone listremotes 2>/dev/null || true)

    if [ ${#RCLONE_REMOTES[@]} -gt 0 ]; then
        echo "    Detected configured rclone remotes: ${RCLONE_REMOTES[*]}"
        # If any remote has 'put' in the name, prioritize it as the default
        for r in "${RCLONE_REMOTES[@]}"; do
            if [[ "$r" =~ [Pp][Uu][Tt] ]]; then
                DEFAULT_REMOTE="$r"
                break
            fi
        done
        # Otherwise default to the first available remote
        [ -z "$DEFAULT_REMOTE" ] && DEFAULT_REMOTE="${RCLONE_REMOTES[0]}"
    fi
else
    echo "[!] Warning: 'rclone' command not found. You will need rclone to use Put.io syncing."
    if command -v apt-get >/dev/null 2>&1; then
        echo "    (You can install it with: sudo apt install rclone)"
    fi
fi
echo ""

# Helper to read input or fall back to default
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
for cand in "$HOME/Jellyfin/downloads" "$HOME/downloads" "$HOME/Downloads" "/volume1/home/$USER/Jellyfin/downloads" "/volume1/downloads" "/media/downloads"; do
    if [ -d "$cand" ]; then
        DETECTED_DOWNLOADS="$cand"
        break
    fi
done
DEFAULT_DOWNLOADS="${DETECTED_DOWNLOADS:-$HOME/Jellyfin/downloads}"

DETECTED_MEDIA=""
for cand in "$HOME/Jellyfin/media" "$HOME/media" "$HOME/Media" "/volume1/home/$USER/Jellyfin/media" "/volume1/media" "/volume1/video" "/media"; do
    if [ -d "$cand" ]; then
        DETECTED_MEDIA="$cand"
        break
    fi
done
DEFAULT_MEDIA="${DETECTED_MEDIA:-$HOME/Jellyfin/media}"

# --- Interactive Path Prompts ---
echo "------------------------------------------------"
echo " Configuration Setup"
echo " (Press ENTER to accept auto-detected or default values)"
echo "------------------------------------------------"

# 1. Downloads Staging Directory
INPUT_DOWNLOADS=$(prompt_with_default "Enter Downloads / Ingest Staging Directory" "$DEFAULT_DOWNLOADS")
DOWNLOADS_DIR="${INPUT_DOWNLOADS/#\~/$HOME}"

# 2. Jellyfin Media Root Directory
INPUT_MEDIA=$(prompt_with_default "Enter Jellyfin Media Root Directory" "$DEFAULT_MEDIA")
MEDIA_DIR="${INPUT_MEDIA/#\~/$HOME}"

# 3. Post-Sort Source Cleanup Mode
DEFAULT_CLEANUP="none"
echo ""
echo "Source cleanup mode after linking (options: 'none' [safe for seeding], 'delete' [remove source], 'move' [archive source]):"
INPUT_CLEANUP=$(prompt_with_default "Enter cleanup mode (none/delete/move)" "$DEFAULT_CLEANUP")
CLEANUP_MODE="$INPUT_CLEANUP"

ARCHIVE_DIR=""
if [ "$CLEANUP_MODE" = "move" ]; then
    DEFAULT_ARCHIVE="$HOME/Jellyfin/processed"
    INPUT_ARCHIVE=$(prompt_with_default "Enter archive directory for processed files" "$DEFAULT_ARCHIVE")
    ARCHIVE_DIR="${INPUT_ARCHIVE/#\~/$HOME}"
fi

# 4. Subtitle Downloading
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

# 5. Rclone Remote Name (auto-detected from rclone config)
echo ""
INPUT_REMOTE=$(prompt_with_default "Enter rclone remote name for Put.io (detected: $DEFAULT_REMOTE)" "$DEFAULT_REMOTE")
REMOTE_NAME="$INPUT_REMOTE"

# 6. Jellyfin Server Auto-Detection & Library Auto-Refresh
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

# 7. Installation Directory for scripts
INPUT_INSTALL_DIR=$(prompt_with_default "Enter directory to install executable scripts" "$DEFAULT_INSTALL_DIR")
INSTALL_DIR="${INPUT_INSTALL_DIR/#\~/$HOME}"

# 8. Config file destination
if [ "$EUID" -eq 0 ]; then
    DEFAULT_CONF="/etc/jellyfin-reel-sort.conf"
else
    DEFAULT_CONF="$HOME/.config/jellyfin-reel-sort.conf"
fi
INPUT_CONF=$(prompt_with_default "Enter path for configuration file" "$DEFAULT_CONF")
CONF_PATH="${INPUT_CONF/#\~/$HOME}"

echo ""
echo "[+] Target settings confirmed:"
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
mkdir -p "$DOWNLOADS_DIR"
mkdir -p "$MEDIA_DIR/Shows"
mkdir -p "$MEDIA_DIR/Movies"
[ -n "$ARCHIVE_DIR" ] && mkdir -p "$ARCHIVE_DIR"
mkdir -p "$INSTALL_DIR"
mkdir -p "$(dirname "$CONF_PATH")"

# Write configuration
echo "[+] Writing configuration to $CONF_PATH..."
cat << CONF_EOF > "$CONF_PATH"
# jellyfin-reel-sort configuration
DOWNLOADS_DIR="$DOWNLOADS_DIR/"
MEDIA_DIR="$MEDIA_DIR/"
SHOWS_DIR="$MEDIA_DIR/Shows/"
MOVIES_DIR="$MEDIA_DIR/Movies/"
CLEANUP_MODE="$CLEANUP_MODE"
ARCHIVE_DIR="$ARCHIVE_DIR"
DOWNLOAD_SUBTITLES="$DOWNLOAD_SUBTITLES"
SUBTITLE_LANGUAGES="$SUBTITLE_LANGUAGES"
PYTHON_BIN="$PYTHON_BIN"
REMOTE_NAME="$REMOTE_NAME"
JELLYFIN_URL="$DEFAULT_JF_URL"
JELLYFIN_API_KEY="$JELLYFIN_API_KEY"
LOG_FILE="$HOME/.local/state/jellyfin-reel-sort/sync.log"
LOCK_FILE="/tmp/jellyfin_reel_sort.lock"
SORTER_PATH="$INSTALL_DIR/sorter.py"
SYNC_TRANSFERS="1"
SYNC_STREAMS="8"
CONF_EOF

# Copy scripts to INSTALL_DIR
echo "[+] Installing scripts into $INSTALL_DIR..."
cp "$SCRIPT_DIR/sorter.py" "$INSTALL_DIR/sorter.py"
cp "$SCRIPT_DIR/putsync.sh" "$INSTALL_DIR/putsync.sh"
cp "$SCRIPT_DIR/initial-import.sh" "$INSTALL_DIR/initial-import.sh" 2>/dev/null || true
cp "$SCRIPT_DIR/delete.sh" "$INSTALL_DIR/delete.sh" 2>/dev/null || true
cp "$SCRIPT_DIR/get_movie.sh" "$INSTALL_DIR/get_movie.sh" 2>/dev/null || true
cp "$SCRIPT_DIR/jellyfin-docker-setup.sh" "$INSTALL_DIR/jellyfin-docker-setup.sh" 2>/dev/null || true

# Setup convenience symlinks in INSTALL_DIR
ln -sf "$INSTALL_DIR/get_movie.sh" "$INSTALL_DIR/get_media.sh" 2>/dev/null || true
ln -sf "$INSTALL_DIR/initial-import.sh" "$INSTALL_DIR/import_media.sh" 2>/dev/null || true
ln -sf "$INSTALL_DIR/jellyfin-docker-setup.sh" "$INSTALL_DIR/docker-reinstall.sh" 2>/dev/null || true

chmod +x "$INSTALL_DIR/sorter.py"
chmod +x "$INSTALL_DIR"/*.sh 2>/dev/null || true

# Ensure user state/log directory exists
mkdir -p "$HOME/.local/state/jellyfin-reel-sort"

echo ""
echo "================================================"
echo "    Installation Complete!"
echo "================================================"
echo "Scripts installed:"
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
echo "  JELLYFIN_SORT_CONFIG=\"$CONF_PATH\" $INSTALL_DIR/putsync.sh"
echo ""
echo "To automate with cron (every 5 mins), add to crontab:"
echo "  */5 * * * * JELLYFIN_SORT_CONFIG=\"$CONF_PATH\" $INSTALL_DIR/putsync.sh >/dev/null 2>&1"
echo "================================================"
