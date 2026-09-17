import os
import sys
import shutil
from guessit import guessit

# Subliminal subtitle downloading imports
try:
    from subliminal import Episode, Movie, download_best_subtitles, save_subtitles
    from babelfish import Language
    SUBLIMINAL_AVAILABLE = True
except ImportError:
    SUBLIMINAL_AVAILABLE = False

# Defaults that can be overridden via environment variables or config file
CONFIG_PATH = os.environ.get("JELLYFIN_SORT_CONFIG", "/etc/jellyfin-reel-sort.conf")

DOWNLOADS_DIR = os.environ.get("DOWNLOADS_DIR", "")
MEDIA_DIR = os.environ.get("MEDIA_DIR", "")
CLEANUP_MODE = os.environ.get("CLEANUP_MODE", "")  # 'delete', 'move', or 'none'
ARCHIVE_DIR = os.environ.get("ARCHIVE_DIR", "")
DOWNLOAD_SUBTITLES = os.environ.get("DOWNLOAD_SUBTITLES", "")  # 'true' or 'false'
SUBTITLE_LANGUAGES = os.environ.get("SUBTITLE_LANGUAGES", "")  # comma-separated codes, e.g. 'en', 'es'

def load_config():
    global DOWNLOADS_DIR, MEDIA_DIR, CLEANUP_MODE, ARCHIVE_DIR, DOWNLOAD_SUBTITLES, SUBTITLE_LANGUAGES
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
                    elif key == "DOWNLOAD_SUBTITLES" and not DOWNLOAD_SUBTITLES:
                        DOWNLOAD_SUBTITLES = val
                    elif key == "SUBTITLE_LANGUAGES" and not SUBTITLE_LANGUAGES:
                        SUBTITLE_LANGUAGES = val

    # Fallback defaults if not set in config or environment
    if not DOWNLOADS_DIR:
        DOWNLOADS_DIR = os.path.expanduser("~/Jellyfin/downloads/")
    if not MEDIA_DIR:
        MEDIA_DIR = os.path.expanduser("~/Jellyfin/media/")
    if not CLEANUP_MODE:
        CLEANUP_MODE = "none"
    if not ARCHIVE_DIR:
        ARCHIVE_DIR = os.path.expanduser("~/Jellyfin/processed/")
    if not DOWNLOAD_SUBTITLES:
        DOWNLOAD_SUBTITLES = "true"
    if not SUBTITLE_LANGUAGES:
        SUBTITLE_LANGUAGES = "en"

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

def fetch_subtitles(dest_path, media_type, info, show_name=None, s_num=None, e_num=None, movie_name=None, year=None):
    """Download subtitles using subliminal and save them in Jellyfin format: MovieName.en.srt"""
    if not SUBLIMINAL_AVAILABLE:
        print("  -> Subliminal library not installed, skipping subtitle download.")
        return

    if DOWNLOAD_SUBTITLES.lower() not in ("true", "1", "yes"):
        return

    dest_dir = os.path.dirname(dest_path)
    base_stem = os.path.splitext(os.path.basename(dest_path))[0]

    # Parse configured language codes into babelfish Language objects
    languages = set()
    for code in SUBTITLE_LANGUAGES.split(','):
        code = code.strip().lower()
        if code:
            try:
                languages.add(Language(code))
            except Exception as e:
                print(f"  -> Warning: Invalid language code '{code}': {e}")

    if not languages:
        return

    # Check if subtitle files already exist in destination directory
    missing_languages = set()
    for lang in languages:
        code_2 = lang.alpha2
        code_3 = lang.alpha3
        existing = [
            f"{base_stem}.{code_2}.srt",
            f"{base_stem}.{code_3}.srt",
            f"{base_stem}.{code_2}.sub",
            f"{base_stem}.{code_3}.sub",
            f"{base_stem}.{code_2}.vtt",
            f"{base_stem}.{code_3}.vtt",
            f"{base_stem}.srt"
        ]
        if not any(os.path.exists(os.path.join(dest_dir, candidate)) for candidate in existing):
            missing_languages.add(lang)

    if not missing_languages:
        return

    print(f"  -> Fetching subtitles for: {base_stem} ({', '.join(l.alpha2 for l in missing_languages)})")

    try:
        if media_type == 'episode':
            guess = {
                'title': show_name,
                'season': s_num,
                'episode': e_num,
                'type': 'episode'
            }
            if year:
                guess['year'] = year
            video = Episode.fromguess(dest_path, guess)
        else:
            guess = {
                'title': movie_name,
                'type': 'movie'
            }
            if year:
                guess['year'] = year
            video = Movie.fromguess(dest_path, guess)

        subtitles = download_best_subtitles([video], missing_languages)
        if subtitles.get(video):
            saved = save_subtitles(video, subtitles[video], directory=dest_dir, language_format='alpha2')
            for s in saved:
                print(f"  -> Saved subtitle: {base_stem}.{s.language.alpha2}.srt")
        else:
            print("  -> No subtitles found from providers.")
    except Exception as e:
        print(f"  -> Subtitle download error: {e}")

def process_files():
    load_config()
    print(f"Scanning downloads directory: {DOWNLOADS_DIR}")
    print(f"Target media directory: {MEDIA_DIR}")
    print(f"Cleanup mode: {CLEANUP_MODE}")
    if CLEANUP_MODE == 'move':
        print(f"Archive directory: {ARCHIVE_DIR}")
    print(f"Download subtitles: {DOWNLOAD_SUBTITLES} ({SUBTITLE_LANGUAGES})")

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
                    year = info.get('year')
                    
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
                            fetch_subtitles(dest_path, 'episode', info, show_name=show_name, s_num=s_num, e_num=e_num, year=year)
                            cleanup_source(source_path)
                        except Exception as e:
                            print(f"Error linking {file}: {e}")
                    else:
                        fetch_subtitles(dest_path, 'episode', info, show_name=show_name, s_num=s_num, e_num=e_num, year=year)

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
                            fetch_subtitles(dest_path, 'movie', info, movie_name=movie_name, year=year)
                            cleanup_source(source_path)
                        except Exception as e:
                            print(f"Error linking {file}: {e}")
                    else:
                        fetch_subtitles(dest_path, 'movie', info, movie_name=movie_name, year=year)
                else:
                    # Log files that don't match movie/show patterns
                    print(f"Skipped (unrecognized format): {file}")

if __name__ == "__main__":
    process_files()
