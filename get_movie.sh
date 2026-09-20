#!/bin/bash

# ==============================================================================
# Jellyfin Reel Sort — Single Movie & Media Downloader
# Interactively selects a movie or show from Put.io / rclone remote,
# prompts for download concurrency, downloads via multi-threaded streams,
# and sorts/hardlinks it directly into your Jellyfin library.
# ==============================================================================

set -e

# Text formatting
BOLD="\033[1m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[36m"
MAGENTA="\033[35m"
RESET="\033[0m"

# 1. Discover and load configuration
CONFIG_FILE="${JELLYFIN_SORT_CONFIG:-}"
if [ -z "$CONFIG_FILE" ] || [ ! -f "$CONFIG_FILE" ]; then
    if [ -f "/etc/jellyfin-reel-sort.conf" ]; then
        CONFIG_FILE="/etc/jellyfin-reel-sort.conf"
    else
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
    CONFIG_OWNER_HOME="$(dirname "$(dirname "$CONFIG_FILE")")"
else
    CONFIG_OWNER_HOME="$HOME"
fi

# Path fallbacks
DOWNLOADS_DIR="${DOWNLOADS_DIR:-$HOME/Jellyfin/downloads/}"
MEDIA_DIR="${MEDIA_DIR:-$HOME/Jellyfin/media/}"
SHOWS_DIR="${SHOWS_DIR:-$MEDIA_DIR/Shows/}"
MOVIES_DIR="${MOVIES_DIR:-$MEDIA_DIR/Movies/}"
REMOTE_NAME="${REMOTE_NAME:-put.io}"
SORTER_SCRIPT="${SORTER_PATH:-$(dirname "$0")/sorter.py}"

# Resolve Python interpreter
if [ -n "$PYTHON_BIN" ] && [ -x "$PYTHON_BIN" ]; then
    PY_CMD="$PYTHON_BIN"
elif [ -x "$CONFIG_OWNER_HOME/.local/share/jellyfin-reel-sort/venv/bin/python3" ]; then
    PY_CMD="$CONFIG_OWNER_HOME/.local/share/jellyfin-reel-sort/venv/bin/python3"
else
    PY_CMD="$(command -v python3)"
fi

# Detect rclone config location
RCLONE_CMD=(rclone)
if [ -z "$RCLONE_CONFIG" ]; then
    if [ -f "$HOME/.config/rclone/rclone.conf" ]; then
        export RCLONE_CONFIG="$HOME/.config/rclone/rclone.conf"
    elif [ -f "/root/.config/rclone/rclone.conf" ] && [ -r "/root/.config/rclone/rclone.conf" ]; then
        export RCLONE_CONFIG="/root/.config/rclone/rclone.conf"
    fi
fi

# Verify rclone command works
if ! command -v rclone >/dev/null 2>&1; then
    echo -e "${RED}[!] Error: 'rclone' command not found in PATH.${RESET}"
    exit 1
fi

# Test remote accessibility
check_remote() {
    if ! "${RCLONE_CMD[@]}" listremotes 2>/dev/null | grep -q "^${REMOTE_NAME}:"; then
        # Try checking if root has the config and we have sudo
        if [ -f "/root/.config/rclone/rclone.conf" ] && [ "$(id -u)" -ne 0 ]; then
            echo -e "${YELLOW}[!] Note: rclone.conf is owned by root. Re-running with sudo...${RESET}"
            exec sudo bash "$0" "$@"
        fi
    fi
}
check_remote

prompt_concurrency() {
    echo ""
    echo -e "${BOLD}${CYAN}------------------------------------------------------${RESET}"
    echo -e "${BOLD}Concurrency Settings:${RESET}"
    echo -e "  Number of parallel streams / connections to use."
    echo -e "  (Higher concurrency splits large movie files into simultaneous"
    echo -e "   multi-threaded chunks to maximize your download speed)."
    echo -e "${BOLD}${CYAN}------------------------------------------------------${RESET}"
    read -r -p "Enter concurrency level [1-32, default 8]: " user_conc

    if [[ "$user_conc" =~ ^[0-9]+$ ]] && [ "$user_conc" -ge 1 ] && [ "$user_conc" -le 64 ]; then
        CONCURRENCY="$user_conc"
    else
        CONCURRENCY=8
    fi
    echo -e "${GREEN}✓ Concurrency set to:${RESET} ${BOLD}${CONCURRENCY} parallel streams${RESET}"
}

download_and_sort() {
    local remote_path="$1"
    prompt_concurrency

    local dest_file="$DOWNLOADS_DIR/$remote_path"
    local dest_dir
    dest_dir="$(dirname "$dest_file")"
    mkdir -p "$dest_dir"

    echo ""
    echo -e "${BOLD}${CYAN}======================================================${RESET}"
    echo -e "${BOLD}Starting Single Movie/Media Download${RESET}"
    echo -e "${BOLD}${CYAN}======================================================${RESET}"
    echo -e "  Remote source: ${CYAN}$REMOTE_NAME:/$remote_path${RESET}"
    echo -e "  Destination:   ${GREEN}$dest_file${RESET}"
    echo -e "  Concurrency:   ${BOLD}${CONCURRENCY} streams${RESET}"
    echo -e "${BOLD}${CYAN}------------------------------------------------------${RESET}"
    echo ""

    # Download main movie file with multi-threading
    "${RCLONE_CMD[@]}" copyto "$REMOTE_NAME:/$remote_path" "$dest_file" \
        --progress \
        --transfers "$CONCURRENCY" \
        --multi-thread-streams "$CONCURRENCY" \
        --checkers "$CONCURRENCY"

    # Also grab any accompanying subtitles in the same remote folder
    local remote_dir
    remote_dir="$(dirname "$remote_path")"
    local file_base
    file_base="$(basename "${remote_path%.*}")"

    if [ "$remote_dir" != "." ]; then
        "${RCLONE_CMD[@]}" copy "$REMOTE_NAME:/$remote_dir" "$dest_dir" \
            --include "${file_base}*.srt" \
            --include "${file_base}*.vtt" \
            --include "*[Ss][Uu][Bb][Ss]*/**" 2>/dev/null || true
    fi

    # Fix ownership if running as root
    local media_owner
    media_owner="$(stat -c '%U' "$DOWNLOADS_DIR" 2>/dev/null || echo '')"
    if [ -n "$media_owner" ] && [ "$media_owner" != "root" ] && [ "$(id -u)" -eq 0 ]; then
        chown -R "$media_owner" "$dest_dir" 2>/dev/null || true
    fi

    echo ""
    echo -e "${GREEN}${BOLD}✓ Download complete!${RESET}"
    echo -e "${CYAN}[+] Sorting and linking into Jellyfin library...${RESET}"
    echo ""

    # Run sorter targeted directly at this download
    "$PY_CMD" "$SORTER_SCRIPT" "$dest_file"

    echo ""
    echo -e "${GREEN}${BOLD}======================================================${RESET}"
    echo -e "${GREEN}${BOLD}All done! Your movie is now available in Jellyfin.${RESET}"
    echo -e "${GREEN}${BOLD}======================================================${RESET}"
    read -r -p "Press Enter to return to menu..." _
}

search_remote() {
    clear
    echo -e "${BOLD}${CYAN}=== Search Movie/Media on $REMOTE_NAME ===${RESET}"
    read -r -p "Enter movie or title keyword (e.g. Inception, 2024): " keyword

    if [ -z "$keyword" ]; then
        return
    fi

    echo -e "\n${CYAN}[+] Searching $REMOTE_NAME for '*$keyword*'...${RESET}"

    local -a matches=()
    while IFS= read -r item; do
        if [ -n "$item" ]; then
            matches+=("$item")
        fi
    done < <("${RCLONE_CMD[@]}" lsf "$REMOTE_NAME:/" --recursive \
        --include "*.{mkv,mp4,avi,MKV,MP4,AVI}" 2>/dev/null | grep -i "$keyword" || true)

    if [ ${#matches[@]} -eq 0 ]; then
        echo -e "${YELLOW}No video files matching '$keyword' found on $REMOTE_NAME.${RESET}"
        read -r -p "Press Enter to continue..." _
        return
    fi

    echo ""
    echo -e "${BOLD}Found ${#matches[@]} match(es):${RESET}"
    for i in "${!matches[@]}"; do
        printf "  ${BOLD}%2d)${RESET} %s\n" "$((i+1))" "${matches[$i]}"
    done
    echo ""
    read -r -p "Select a number to download (or 0 to cancel): " sel

    if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#matches[@]}" ]; then
        local chosen="${matches[$((sel-1))]}"
        download_and_sort "$chosen"
    fi
}

list_all_remote() {
    clear
    echo -e "${BOLD}${CYAN}=== Available Video Files on $REMOTE_NAME ===${RESET}"
    echo -e "${CYAN}[+] Querying remote file list (this may take a few seconds)...${RESET}"

    local -a files=()
    while IFS= read -r item; do
        if [ -n "$item" ]; then
            files+=("$item")
        fi
    done < <("${RCLONE_CMD[@]}" lsf "$REMOTE_NAME:/" --recursive \
        --include "*.{mkv,mp4,avi,MKV,MP4,AVI}" 2>/dev/null | sort || true)

    if [ ${#files[@]} -eq 0 ]; then
        echo -e "${YELLOW}No video files (.mkv, .mp4, .avi) found on $REMOTE_NAME.${RESET}"
        read -r -p "Press Enter to continue..." _
        return
    fi

    echo ""
    echo -e "${BOLD}Found ${#files[@]} video file(s):${RESET}"
    for i in "${!files[@]}"; do
        printf "  ${BOLD}%2d)${RESET} %s\n" "$((i+1))" "${files[$i]}"
    done
    echo ""
    read -r -p "Select a number to download (or 0 to cancel): " sel

    if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#files[@]}" ]; then
        local chosen="${files[$((sel-1))]}"
        download_and_sort "$chosen"
    fi
}

manual_path_entry() {
    clear
    echo -e "${BOLD}${CYAN}=== Manual Remote Path Entry ===${RESET}"
    echo -e "Enter the exact path as shown on $REMOTE_NAME."
    echo -e "Example: ${CYAN}putflix/Dune (2024)/Dune.Part.Two.2024.1080p.mkv${RESET}"
    echo ""
    read -r -p "Remote Path: " raw_path

    # Clean leading slashes
    raw_path="${raw_path#/}"

    if [ -z "$raw_path" ]; then
        return
    fi

    echo -e "\n${CYAN}[+] Checking if file exists on $REMOTE_NAME...${RESET}"
    if "${RCLONE_CMD[@]}" ls "$REMOTE_NAME:/$raw_path" 2>/dev/null | grep -q .; then
        echo -e "${GREEN}✓ File verified on remote!${RESET}"
        download_and_sort "$raw_path"
    else
        echo -e "${RED}[!] Could not locate '$raw_path' on $REMOTE_NAME.${RESET}"
        read -r -p "Press Enter to continue..." _
    fi
}

# Main Interactive Menu
while true; do
    clear
    echo -e "${BOLD}${CYAN}======================================================${RESET}"
    echo -e "${BOLD}   Jellyfin Reel Sort — Single Movie Downloader       ${RESET}"
    echo -e "${BOLD}${CYAN}======================================================${RESET}"
    echo -e "  Remote Name:     ${CYAN}$REMOTE_NAME${RESET}"
    echo -e "  Downloads Dir:   ${GREEN}$DOWNLOADS_DIR${RESET}"
    echo -e "  Movies Library:  ${GREEN}$MOVIES_DIR${RESET}"
    echo -e "  Shows Library:   ${GREEN}$SHOWS_DIR${RESET}"
    echo -e "${BOLD}${CYAN}------------------------------------------------------${RESET}"
    echo -e "  ${BOLD}1)${RESET} Search for a Movie/Media by Keyword"
    echo -e "  ${BOLD}2)${RESET} List All Available Videos on $REMOTE_NAME"
    echo -e "  ${BOLD}3)${RESET} Enter Remote Path Manually"
    echo -e "  ${BOLD}4)${RESET} Exit"
    echo -e "${BOLD}${CYAN}------------------------------------------------------${RESET}"
    read -r -p "Enter choice [1-4]: " menu_choice

    case "$menu_choice" in
        1) search_remote ;;
        2) list_all_remote ;;
        3) manual_path_entry ;;
        4|q|Q)
            echo -e "\nGoodbye!"
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid option.${RESET}"
            sleep 1
            ;;
    esac
done
