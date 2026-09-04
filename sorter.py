import os
import sys
from pathlib import Path
from guessit import guessit

# Defaults that can be overridden via environment variables or config file
CONFIG_PATH = os.environ.get("JELLYFIN_SORT_CONFIG", "/etc/jellyfin-reel-sort.conf")

DOWNLOADS_DIR = os.environ.get("DOWNLOADS_DIR", "")
MEDIA_DIR = os.environ.get("MEDIA_DIR", "")

def load_config():
    global DOWNLOADS_DIR, MEDIA_DIR
    if os.path.isfile(CONFIG_PATH):
        with open(CONFIG_PATH, "r") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, val = line.split("=", 1)
                    val = val.strip().strip('"').strip("'")
                    if key.strip() == "DOWNLOADS_DIR" and not DOWNLOADS_DIR:
                        DOWNLOADS_DIR = val
                    elif key.strip() == "MEDIA_DIR" and not MEDIA_DIR:
                        MEDIA_DIR = val

    # Fallback default if not configured
    if not DOWNLOADS_DIR:
        DOWNLOADS_DIR = os.path.expanduser("~/Jellyfin/downloads/")
    if not MEDIA_DIR:
        MEDIA_DIR = os.path.expanduser("~/Jellyfin/media/")

def process_files():
    load_config()
    print(f"Scanning downloads directory: {DOWNLOADS_DIR}")
    print(f"Target media directory: {MEDIA_DIR}")

    if not os.path.exists(DOWNLOADS_DIR):
        print(f"Downloads directory does not exist: {DOWNLOADS_DIR}")
        return

    os.makedirs(MEDIA_DIR, exist_ok=True)

    for root, dirs, files in os.walk(DOWNLOADS_DIR):
        for file in files:
            if file.endswith(('.mkv', '.mp4', '.avi')):
                source_path = os.path.join(root, file)
                info = guessit(file)
                
                # --- HANDLE TV SHOWS ---
                if 'title' in info and 'season' in info and 'episode' in info:
                    show_name = str(info['title']).title()
                    
                    # Handle multi-episodes safely
                    s_num = info['season'][0] if isinstance(info['season'], list) else info['season']
                    e_num = info['episode'][0] if isinstance(info['episode'], list) else info['episode']
                    
                    season_folder = f"Season {s_num:02d}"
                    ext = os.path.splitext(file)[1]
                    
                    # Create clean file name: "Show Name - S01E02.mkv"
                    clean_name = f"{show_name} - S{s_num:02d}E{e_num:02d}{ext}"
                    
                    dest_dir = os.path.join(MEDIA_DIR, 'Shows', show_name, season_folder)
                    dest_path = os.path.join(dest_dir, clean_name)
                    
                    os.makedirs(dest_dir, exist_ok=True)
                    if not os.path.exists(dest_path):
                        try:
                            os.link(source_path, dest_path)
                            print(f"Linked Show: {clean_name}")
                        except Exception as e:
                            print(f"Error linking {file}: {e}")

                # --- HANDLE MOVIES ---
                elif 'title' in info and info.get('type') == 'movie':
                    movie_name = str(info['title']).title()
                    year = info.get('year', '')
                    
                    # Create clean folder/file name: "Movie Name (2023)"
                    folder_name = f"{movie_name} ({year})" if year else movie_name
                    ext = os.path.splitext(file)[1]
                    clean_name = f"{folder_name}{ext}"
                    
                    dest_dir = os.path.join(MEDIA_DIR, 'Movies', folder_name)
                    dest_path = os.path.join(dest_dir, clean_name)
                    
                    os.makedirs(dest_dir, exist_ok=True)
                    if not os.path.exists(dest_path):
                        try:
                            os.link(source_path, dest_path)
                            print(f"Linked Movie: {clean_name}")
                        except Exception as e:
                            print(f"Error linking {file}: {e}")

if __name__ == "__main__":
    process_files()
