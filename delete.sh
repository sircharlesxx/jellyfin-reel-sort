#!/bin/bash

# ==============================================================================
# Interactive Media Deletion Tool for Jellyfin Reel Sort
# Safely deletes media from:
#   1. Jellyfin Library (Shows / Movies)
#   2. Downloads Folder (frees hardlink disk space)
#   3. (Optional) Put.io Remote (prevents re-downloading)
#   4. Triggers automatic Jellyfin library refresh
# ==============================================================================

# Text formatting
BOLD="\033[1m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[36m"
RESET="\033[0m"

# Configuration file discovery
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
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    CONFIG_OWNER_HOME="$(dirname "$(dirname "$CONFIG_FILE")")"
else
    CONFIG_OWNER_HOME="$HOME"
fi

SOURCE_FILE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE_FILE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE_FILE")" && pwd)"
    SOURCE_FILE="$(readlink "$SOURCE_FILE")"
    [[ $SOURCE_FILE != /* ]] && SOURCE_FILE="$DIR/$SOURCE_FILE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE_FILE")" && pwd)"

# Automatically ensure CLI helper scripts in ~/.local/bin/ are symlinked to this repository
auto_symlink_scripts() {
    local bin_dir="$CONFIG_OWNER_HOME/.local/bin"
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
}
auto_symlink_scripts

# Path fallbacks
MEDIA_DIR="${MEDIA_DIR:-$HOME/Jellyfin/media/}"
SHOWS_DIR="${SHOWS_DIR:-${MEDIA_DIR%/}/Shows}"
MOVIES_DIR="${MOVIES_DIR:-${MEDIA_DIR%/}/Movies}"
DOWNLOADS_DIR="${DOWNLOADS_DIR:-$HOME/Jellyfin/downloads/}"
REMOTE_NAME="${REMOTE_NAME:-put.io}"

# Optional Jellyfin URL / API key
JELLYFIN_URL="${JELLYFIN_URL:-http://localhost:8096}"
JELLYFIN_API_KEY="${JELLYFIN_API_KEY:-}"

refresh_jellyfin() {
    if [ -n "$JELLYFIN_API_KEY" ] && command -v curl >/dev/null 2>&1; then
        echo -e "${CYAN}[+] Triggering Jellyfin library scan...${RESET}"
        curl -s -X POST "$JELLYFIN_URL/Library/Refresh" -H "X-Emby-Token: $JELLYFIN_API_KEY" >/dev/null 2>&1 || true
    fi
}

delete_target() {
    local title="$1"
    local media_type="$2" # "show" or "movie"
    local media_path=""

    if [ "$media_type" = "show" ]; then
        media_path="${SHOWS_DIR%/}/$title"
    else
        media_path="${MOVIES_DIR%/}/$title"
    fi

    # Clean title (strip release year and prepare dot/wildcard pattern for download filenames)
    local title_clean
    title_clean="$(echo "$title" | sed -E 's/ \([0-9]{4}\)//')"
    local title_search
    title_search="$(echo "$title_clean" | tr ' ' '*')"

    echo ""
    echo -e "${BOLD}======================================================${RESET}"
    echo -e "${YELLOW}Selected:${RESET} ${BOLD}$title${RESET} (${media_type})"
    echo -e "${BOLD}======================================================${RESET}"

    # 1. Check Jellyfin Media folder
    echo -e "\n${BOLD}[1] Jellyfin Media Library:${RESET}"
    if [ -e "$media_path" ]; then
        local media_size
        media_size="$(du -sh "$media_path" 2>/dev/null | cut -f1)"
        echo -e "  Found: ${GREEN}$media_path${RESET} (${media_size})"
    else
        echo -e "  ${YELLOW}Not found in $media_path${RESET}"
    fi

    # 2. Check Downloads folder for matching files / folders
    echo -e "\n${BOLD}[2] Downloads folder matches:${RESET}"
    local -a dl_matches=()
    while IFS= read -r match; do
        if [ -n "$match" ]; then
            dl_matches+=("$match")
            local dl_size
            dl_size="$(du -sh "$match" 2>/dev/null | cut -f1)"
            echo -e "  Found: ${GREEN}$match${RESET} (${dl_size})"
        fi
    done < <(find "$DOWNLOADS_DIR" -maxdepth 3 \( -iname "*$title*" -o -iname "*$title_search*" \) 2>/dev/null | sort -u || true)

    if [ ${#dl_matches[@]} -eq 0 ]; then
        echo -e "  ${YELLOW}No matching source files found in $DOWNLOADS_DIR${RESET}"
    fi

    # 3. Check Put.io remote for matches
    echo -e "\n${BOLD}[3] Put.io Remote matches:${RESET}"
    local -a remote_matches=()
    if command -v rclone >/dev/null 2>&1; then
        while IFS= read -r rmatch; do
            if [ -n "$rmatch" ]; then
                remote_matches+=("$rmatch")
                echo -e "  Found on Put.io: ${CYAN}$rmatch${RESET}"
            fi
        done < <(rclone lsf "$REMOTE_NAME:/" 2>/dev/null | grep -iE "($title|$title_clean)" || true)

        # Also search in putflix/ subfolder if exists
        while IFS= read -r rmatch; do
            if [ -n "$rmatch" ]; then
                remote_matches+=("putflix/$rmatch")
                echo -e "  Found on Put.io: ${CYAN}putflix/$rmatch${RESET}"
            fi
        done < <(rclone lsf "$REMOTE_NAME:/putflix/" 2>/dev/null | grep -iE "($title|$title_clean)" || true)
    fi

    if [ ${#remote_matches[@]} -eq 0 ]; then
        echo -e "  ${YELLOW}No matching files found on Put.io${RESET}"
    fi

    echo ""
    echo -e "${RED}${BOLD}WARNING: This action is permanent!${RESET}"
    read -r -p "Delete from your NAS (Jellyfin library & downloads)? [y/N]: " confirm_nas
    if [[ "$confirm_nas" =~ ^[Yy]$ ]]; then
        # Delete from Media Library
        if [ -e "$media_path" ]; then
            rm -rf "$media_path"
            echo -e "${GREEN}  ✓ Deleted from Jellyfin:${RESET} $media_path"
        fi

        # Delete from Downloads folder
        for dl in "${dl_matches[@]}"; do
            if [ -e "$dl" ]; then
                rm -rf "$dl"
                echo -e "${GREEN}  ✓ Deleted from Downloads:${RESET} $dl"
            fi
        done

        refresh_jellyfin
        echo -e "${GREEN}${BOLD}✓ Local media successfully deleted and disk space reclaimed!${RESET}"
    else
        echo -e "${YELLOW}Skipping NAS deletion.${RESET}"
    fi

    # Ask about Put.io deletion
    if [ ${#remote_matches[@]} -gt 0 ]; then
        echo ""
        read -r -p "Also delete from Put.io cloud so it never re-downloads? [y/N]: " confirm_putio
        if [[ "$confirm_putio" =~ ^[Yy]$ ]]; then
            for rpath in "${remote_matches[@]}"; do
                echo -e "  Deleting from Put.io: ${CYAN}$rpath${RESET}..."
                # Use purge if it is a directory, delete if file
                rclone purge "$REMOTE_NAME:/$rpath" 2>/dev/null || rclone delete "$REMOTE_NAME:/$rpath" 2>/dev/null || true
                echo -e "${GREEN}  ✓ Removed from Put.io:${RESET} $rpath"
            done
            echo -e "${GREEN}${BOLD}✓ Put.io cloud storage cleaned!${RESET}"
        fi
    fi

    echo ""
    read -r -p "Press Enter to return to menu..." _
}

list_shows() {
    clear
    echo -e "${BOLD}${CYAN}=== TV Shows in Library ===${RESET}"
    if [ ! -d "$SHOWS_DIR" ]; then
        echo -e "${RED}Shows directory does not exist: $SHOWS_DIR${RESET}"
        read -r -p "Press Enter to continue..." _
        return
    fi

    local -a shows=()
    while IFS= read -r s; do
        if [ -n "$s" ]; then
            shows+=("$(basename "$s")")
        fi
    done < <(find "$SHOWS_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

    if [ ${#shows[@]} -eq 0 ]; then
        echo -e "${YELLOW}No TV shows found in $SHOWS_DIR${RESET}"
        read -r -p "Press Enter to continue..." _
        return
    fi

    for i in "${!shows[@]}"; do
        printf "  ${BOLD}%2d)${RESET} %s\n" "$((i+1))" "${shows[$i]}"
    done
    echo ""
    read -r -p "Select a show number to delete (or 0 to cancel): " choice

    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#shows[@]}" ]; then
        local selected="${shows[$((choice-1))]}"
        delete_target "$selected" "show"
    fi
}

list_movies() {
    clear
    echo -e "${BOLD}${CYAN}=== Movies in Library ===${RESET}"
    if [ ! -d "$MOVIES_DIR" ]; then
        echo -e "${RED}Movies directory does not exist: $MOVIES_DIR${RESET}"
        read -r -p "Press Enter to continue..." _
        return
    fi

    local -a movies=()
    while IFS= read -r m; do
        if [ -n "$m" ]; then
            movies+=("$(basename "$m")")
        fi
    done < <(find "$MOVIES_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

    if [ ${#movies[@]} -eq 0 ]; then
        echo -e "${YELLOW}No movies found in $MOVIES_DIR${RESET}"
        read -r -p "Press Enter to continue..." _
        return
    fi

    for i in "${!movies[@]}"; do
        printf "  ${BOLD}%2d)${RESET} %s\n" "$((i+1))" "${movies[$i]}"
    done
    echo ""
    read -r -p "Select a movie number to delete (or 0 to cancel): " choice

    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#movies[@]}" ]; then
        local selected="${movies[$((choice-1))]}"
        delete_target "$selected" "movie"
    fi
}

search_media() {
    clear
    echo -e "${BOLD}${CYAN}=== Search Media to Delete ===${RESET}"
    read -r -p "Enter show or movie title keyword: " query

    if [ -z "$query" ]; then
        return
    fi

    local -a matches=()
    local -a types=()

    # Search Shows
    while IFS= read -r s; do
        if [ -n "$s" ]; then
            matches+=("$(basename "$s")")
            types+=("show")
        fi
    done < <(find "$SHOWS_DIR" -mindepth 1 -maxdepth 1 -type d -iname "*$query*" 2>/dev/null || true)

    # Search Movies
    while IFS= read -r m; do
        if [ -n "$m" ]; then
            matches+=("$(basename "$m")")
            types+=("movie")
        fi
    done < <(find "$MOVIES_DIR" -mindepth 1 -maxdepth 1 -type d -iname "*$query*" 2>/dev/null || true)

    if [ ${#matches[@]} -eq 0 ]; then
        echo -e "${YELLOW}No shows or movies matched '$query'.${RESET}"
        read -r -p "Press Enter to continue..." _
        return
    fi

    echo ""
    echo -e "${BOLD}Matches found:${RESET}"
    for i in "${!matches[@]}"; do
        printf "  ${BOLD}%2d)${RESET} [%s] %s\n" "$((i+1))" "${types[$i]}" "${matches[$i]}"
    done
    echo ""
    read -r -p "Select a number to delete (or 0 to cancel): " choice

    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#matches[@]}" ]; then
        local selected="${matches[$((choice-1))]}"
        local sel_type="${types[$((choice-1))]}"
        delete_target "$selected" "$sel_type"
    fi
}

# Main Menu Loop
while true; do
    clear
    echo -e "${BOLD}${CYAN}======================================================${RESET}"
    echo -e "${BOLD}       Jellyfin Reel Sort — Media Cleanup Tool        ${RESET}"
    echo -e "${BOLD}${CYAN}======================================================${RESET}"
    echo -e "  Shows directory:     ${GREEN}$SHOWS_DIR${RESET}"
    echo -e "  Movies directory:    ${GREEN}$MOVIES_DIR${RESET}"
    echo -e "  Downloads directory: ${GREEN}$DOWNLOADS_DIR${RESET}"
    echo -e "  Put.io remote:       ${CYAN}$REMOTE_NAME${RESET}"
    echo -e "${BOLD}${CYAN}------------------------------------------------------${RESET}"
    echo -e "  ${BOLD}1)${RESET} Browse & Delete a TV Show"
    echo -e "  ${BOLD}2)${RESET} Browse & Delete a Movie"
    echo -e "  ${BOLD}3)${RESET} Search Media by Name"
    echo -e "  ${BOLD}4)${RESET} Exit"
    echo -e "${BOLD}${CYAN}------------------------------------------------------${RESET}"
    read -r -p "Enter your choice [1-4]: " menu_choice

    case "$menu_choice" in
        1) list_shows ;;
        2) list_movies ;;
        3) search_media ;;
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
