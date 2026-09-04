#!/bin/bash
set -e

echo "================================================"
echo "    jellyfin-reel-sort Installer & Setup"
echo "================================================"
echo ""

# Check python3
if ! command -v python3 >/dev/null 2>&1; then
    echo "[-] Error: python3 is required but not installed." >&2
    exit 1
fi

# Check / install guessit
echo "[+] Checking Python dependency (guessit)..."
if ! python3 -c "import guessit" >/dev/null 2>&1; then
    echo "[!] 'guessit' module not found. Installing via pip..."
    if command -v pip3 >/dev/null 2>&1; then
        pip3 install guessit
    elif command -v pip >/dev/null 2>&1; then
        pip install guessit
    else
        echo "[-] Error: Neither pip3 nor pip was found. Please install guessit manually ('pip install guessit')." >&2
        exit 1
    fi
else
    echo "[+] guessit is installed."
fi

# Check rclone
echo "[+] Checking rclone..."
if ! command -v rclone >/dev/null 2>&1; then
    echo "[!] Warning: 'rclone' command not found. You will need rclone to use Put.io syncing."
    echo "    Install rclone with your package manager (e.g. 'sudo apt install rclone' or 'sudo dnf install rclone')."
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

# --- Interactive Path Prompts ---
echo "------------------------------------------------"
echo " Configuration Setup"
echo "------------------------------------------------"

# 1. Downloads Staging Directory
DEFAULT_DOWNLOADS="$HOME/Jellyfin/downloads"
INPUT_DOWNLOADS=$(prompt_with_default "Enter Downloads / Ingest Staging Directory" "$DEFAULT_DOWNLOADS")
DOWNLOADS_DIR="${INPUT_DOWNLOADS/#\~/$HOME}"

# 2. Jellyfin Media Root Directory
DEFAULT_MEDIA="$HOME/Jellyfin/media"
INPUT_MEDIA=$(prompt_with_default "Enter Jellyfin Media Root Directory" "$DEFAULT_MEDIA")
MEDIA_DIR="${INPUT_MEDIA/#\~/$HOME}"

# 3. Rclone Remote Name
DEFAULT_REMOTE="put.io"
INPUT_REMOTE=$(prompt_with_default "Enter rclone remote name for Put.io" "$DEFAULT_REMOTE")
REMOTE_NAME="$INPUT_REMOTE"

# 4. Installation Directory for scripts
DEFAULT_INSTALL_DIR="$HOME/.local/bin"
INPUT_INSTALL_DIR=$(prompt_with_default "Enter directory to install executable scripts" "$DEFAULT_INSTALL_DIR")
INSTALL_DIR="${INPUT_INSTALL_DIR/#\~/$HOME}"

# 5. Config file destination
if [ "$EUID" -eq 0 ]; then
    DEFAULT_CONF="/etc/jellyfin-reel-sort.conf"
else
    DEFAULT_CONF="$HOME/.config/jellyfin-reel-sort.conf"
fi
INPUT_CONF=$(prompt_with_default "Enter path for configuration file" "$DEFAULT_CONF")
CONF_PATH="${INPUT_CONF/#\~/$HOME}"

echo ""
echo "[+] Target settings confirmed:"
echo "  - Ingest Downloads: $DOWNLOADS_DIR"
echo "  - Media Library:    $MEDIA_DIR"
echo "  - Rclone Remote:    $REMOTE_NAME"
echo "  - Install Scripts:  $INSTALL_DIR"
echo "  - Config File:      $CONF_PATH"
echo ""

echo "[+] Preparing directories..."
mkdir -p "$DOWNLOADS_DIR"
mkdir -p "$MEDIA_DIR/Shows"
mkdir -p "$MEDIA_DIR/Movies"
mkdir -p "$INSTALL_DIR"
mkdir -p "$(dirname "$CONF_PATH")"

# Write configuration
echo "[+] Writing configuration to $CONF_PATH..."
cat << CONF_EOF > "$CONF_PATH"
# jellyfin-reel-sort configuration
DOWNLOADS_DIR="$DOWNLOADS_DIR/"
MEDIA_DIR="$MEDIA_DIR/"
REMOTE_NAME="$REMOTE_NAME"
LOG_FILE="$HOME/.local/state/jellyfin-reel-sort/sync.log"
LOCK_FILE="/tmp/jellyfin_reel_sort.lock"
SORTER_PATH="$INSTALL_DIR/sorter.py"
CONF_EOF

# Copy scripts to INSTALL_DIR
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "[+] Installing scripts into $INSTALL_DIR..."
cp "$SCRIPT_DIR/sorter.py" "$INSTALL_DIR/sorter.py"
cp "$SCRIPT_DIR/putsync.sh" "$INSTALL_DIR/putsync.sh"
chmod +x "$INSTALL_DIR/sorter.py"
chmod +x "$INSTALL_DIR/putsync.sh"

# Ensure user state/log directory exists
mkdir -p "$HOME/.local/state/jellyfin-reel-sort"

echo ""
echo "================================================"
echo "    Installation Complete!"
echo "================================================"
echo "Scripts installed:"
echo "  - Sync & Sort Orchestrator: $INSTALL_DIR/putsync.sh"
echo "  - Hardlink Sorter:          $INSTALL_DIR/sorter.py"
echo "Configuration file:           $CONF_PATH"
echo ""
echo "To run manually:"
echo "  JELLYFIN_SORT_CONFIG=\"$CONF_PATH\" $INSTALL_DIR/putsync.sh"
echo ""
echo "To automate with cron (every 30 mins), add to 'crontab -e':"
echo "  */30 * * * * JELLYFIN_SORT_CONFIG=\"$CONF_PATH\" $INSTALL_DIR/putsync.sh >/dev/null 2>&1"
echo "================================================"
