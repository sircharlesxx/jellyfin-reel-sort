import os
import sys
import shutil
from guessit import guessit

# Defaults that can be overridden via environment variables or config file
CONFIG_PATH = os.environ.get("JELLYFIN_SORT_CONFIG", "/etc/jellyfin-reel-sort.conf")

DOWNLOADS_DIR = os.environ.get("DOWNLOADS_DIR", "")
MEDIA_DIR = os.environ.get("MEDIA_DIR", "")
CLEANUP_MODE = os.environ.get("CLEANUP_MODE", "")  # 'delete', 'move', or 'none'
ARCHIVE_DIR = os.environ.get("ARCHIVE_DIR", "")

def load_config():
    global DOWNLOADS_DIR, MEDIA_DIR, CLEANUP_MODE, ARCHIVE_DIR
    if os.path.isfile(CONFIG_PATH):
        with open(CONFIG_PATH, "r") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, val = line.split("=", 1)
                    key = key.strip()
                    val = val.strip().strip('"').strip("'")
                    if key == "DOWNLOADS_DIR" and not DOWNLOADS_DIR:
                        DOWNLOADS_DIR = val
                    elif key == "MEDIA_DIR" and not MEDIA_DIR:
                        MEDIA_DIR = val
                    elif key == "CLEANUP_MODE" and not CLEANUP_MODE:
                        CLEANUP_MODE = val
                    elif key == "ARCHIVE_DIR" and not ARCHIVE_DIR:
                        ARCHIVE_DIR = val

    # Fallback defaults if not set in config or environment
    if not DOWNLOADS_DIR:
        DOWNLOADS_DIR = os.path.expanduser("~/Jellyfin/downloads/")
    if not MEDIA_DIR:
        MEDIA_DIR = os.path.expanduser("~/Jellyfin/media/")
    if not CLEANUP_MODE:
        CLEANUP_MODE = "none"
    if not ARCHIVE_DIR:
        ARCHIVE_DIR = os.path.expanduser("~/Jellyfin/processed/")

def cleanup_source(source_path):
    """Safely remove or archive the source file after successful linking."""
    if CLEANUP_MODE == 'delete':
        try:
            os.remove(source_path)
            print(f"  -> Deleted source: {source_path}")
        except Exception as e:
            print(f"  -> Warning: Failed to delete {source_path}: {e}")
            
    elif CLEANUP_MODE == 'move':
        try:
            os.makedirs(ARCHIVE_DIR, exist_ok=True)
            shutil.move(source_path, ARCHIVE_DIR)
            print(f"  -> Moved source to archive: {source_path}")
        except Exception as e:
            print(f"  -> Warning: Failed to move {source_path}: {e}")
            
    # If 'none', do nothing (preserves original file for seeding)

def process_files():
    load_config()
    print(f"Scanning downloads directory: {DOWNLOADS_DIR}")
    print(f"Target media directory: {MEDIA_DIR}")
    print(f"Cleanup mode: {CLEANUP_MODE}")
    if CLEANUP_MODE == 'move':
        print(f"Archive directory: {ARCHIVE_DIR}")

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
                            cleanup_source(source_path)
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
                            cleanup_source(source_path)
                        except Exception as e:
                            print(f"Error linking {file}: {e}")
                else:
                    # Log files that don't match movie/show patterns
                    print(f"Skipped (unrecognized format): {file}")

if __name__ == "__main__":
    process_files()
