import os
import shutil
from guessit import guessit

# --- Configuration ---
DOWNLOADS_DIR = '/volume1/home/<YOUR_USER_NAME>/Jellyfin/downloads/'
MEDIA_DIR = '/volume1/home/<YOUR_USER_NAME>/Jellyfin/media/'

# Cleanup options: 'delete', 'move', or 'none'
CLEANUP_MODE = 'delete'  # Change to 'move' or 'none' as needed

# Only used if CLEANUP_MODE == 'move'
ARCHIVE_DIR = '/volume1/home/<YOUR_USER_NAME>/Jellyfin/processed/'

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
            
    # If 'none', do nothing

def process_files():
    for root, dirs, files in os.walk(DOWNLOADS_DIR):
        for file in files:
            if file.endswith(('.mkv', '.mp4', '.avi')):
                source_path = os.path.join(root, file)
                info = guessit(file)
                
                # --- HANDLE TV SHOWS ---
                if 'title' in info and 'season' in info and 'episode' in info:
                    show_name = str(info['title']).title()
                    s_num = info['season'][0] if isinstance(info['season'], list) else info['season']
                    e_num = info['episode'][0] if isinstance(info['episode'], list) else info['episode']
                    season_folder = f"Season {s_num:02d}"
                    ext = os.path.splitext(file)[1]
                    clean_name = f"{show_name} - S{s_num:02d}E{e_num:02d}{ext}"
                    dest_dir = os.path.join(MEDIA_DIR, 'Shows', show_name, season_folder)
                    dest_path = os.path.join(dest_dir, clean_name)
                    
                    os.makedirs(dest_dir, exist_ok=True)
                    if not os.path.exists(dest_path):
                        try:
                            os.link(source_path, dest_path)
                            print(f"Linked Show: {clean_name}")
                            cleanup_source(source_path)  # <-- CLEANUP HERE
                        except Exception as e:
                            print(f"Error linking {file}: {e}")

                # --- HANDLE MOVIES ---
                elif 'title' in info and info.get('type') == 'movie':
                    movie_name = str(info['title']).title()
                    year = info.get('year', '')
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
                            cleanup_source(source_path)  # <-- CLEANUP HERE
                        except Exception as e:
                            print(f"Error linking {file}: {e}")
                else:
                    # Log files that don't match movie/show patterns
                    print(f"Skipped (unrecognized format): {file}")

if __name__ == "__main__":
    process_files()