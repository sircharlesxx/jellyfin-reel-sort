import os
import sys
import time
import random
import shutil
import glob
from guessit import guessit

# Rotate realistic desktop browser User-Agents
USER_AGENTS = [
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:125.0) Gecko/20100101 Firefox/125.0",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 14.4; rv:125.0) Gecko/20100101 Firefox/125.0",
    "Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:125.0) Gecko/20100101 Firefox/125.0",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36 Edg/124.0.0.0",
]

# Subliminal subtitle downloading imports & Session Patching
try:
    import requests
    from requests.adapters import HTTPAdapter
    from urllib3.util import Retry

    # Patch requests.Session to inject random User-Agent and safe retry backoff
    _orig_session_init = requests.Session.__init__
    def _patched_session_init(self, *args, **kwargs):
        _orig_session_init(self, *args, **kwargs)
        self.headers['User-Agent'] = random.choice(USER_AGENTS)
        # Configure polite backoff on 429 Too Many Requests and 5xx errors
        retries = Retry(
            total=3,
            backoff_factor=1.5,
            status_forcelist=[429, 500, 502, 503, 504],
            raise_on_status=False
        )
        adapter = HTTPAdapter(max_retries=retries)
        self.mount("https://", adapter)
        self.mount("http://", adapter)

    requests.Session.__init__ = _patched_session_init

    from subliminal import Episode, Movie, Video, scan_video, download_best_subtitles, save_subtitles
    from babelfish import Language

    # Configure subliminal's dogpile.cache region — required before any download calls.
    # Without this, accessing region._lock_registry raises AttributeError.
    try:
        from subliminal.cache import region as _subliminal_region
        if not _subliminal_region.is_configured:
            _cache_dir = os.path.expanduser("~/.cache/jellyfin-reel-sort")
            os.makedirs(_cache_dir, exist_ok=True)
            _subliminal_region.configure(
                'dogpile.cache.dbm',
                expiration_time=3600,
                arguments={'filename': os.path.join(_cache_dir, 'subliminal.dbm')}
            )
    except Exception as _e:
        # Fallback: in-memory cache (no persistence, but fully functional)
        try:
            from subliminal.cache import region as _subliminal_region
            if not _subliminal_region.is_configured:
                _subliminal_region.configure('dogpile.cache.memory')
        except Exception:
            pass  # Non-fatal: subtitle downloads may still work without caching

    SUBLIMINAL_AVAILABLE = True
except ImportError:
    SUBLIMINAL_AVAILABLE = False

# Defaults that can be overridden via environment variables or config file
CONFIG_PATH = os.environ.get("JELLYFIN_SORT_CONFIG", "/etc/jellyfin-reel-sort.conf")

DOWNLOADS_DIR = os.environ.get("DOWNLOADS_DIR", "")
MEDIA_DIR = os.environ.get("MEDIA_DIR", "")
SHOWS_DIR = os.environ.get("SHOWS_DIR", "")
MOVIES_DIR = os.environ.get("MOVIES_DIR", "")
CLEANUP_MODE = os.environ.get("CLEANUP_MODE", "")  # 'delete', 'move', or 'none'
ARCHIVE_DIR = os.environ.get("ARCHIVE_DIR", "")
DOWNLOAD_SUBTITLES = os.environ.get("DOWNLOAD_SUBTITLES", "")  # 'true' or 'false'
SUBTITLE_LANGUAGES = os.environ.get("SUBTITLE_LANGUAGES", "")  # comma-separated codes, e.g. 'en', 'es'
SUBTITLE_DELAY = float(os.environ.get("SUBTITLE_DELAY", "2.0"))  # Seconds to wait between API calls to avoid rate limits

def parse_language(code):
    """Robustly parse any language code (2-letter, 3-letter, or IETF) into a babelfish Language object."""
    code = code.strip()
    if not code:
        return None
    for method in (Language.fromietf, Language.fromalpha2, Language.fromalpha3b, Language.fromalpha3t, Language):
        try:
            return method(code)
        except Exception:
            pass
    return None

def discover_directory(candidates, label="directory"):
    """Check a list of candidate path patterns/strings and return the first existing directory."""
    for item in candidates:
        if not item:
            continue
        expanded = os.path.expanduser(item)
        matches = glob.glob(expanded)
        for match in sorted(matches):
            if os.path.isdir(match):
                return os.path.abspath(match)
    return None

def find_subfolder_ci(parent_dir, target_name):
    """Case-insensitive search for a subfolder (e.g. 'shows' or 'movies') inside parent_dir."""
    if not parent_dir or not os.path.isdir(parent_dir):
        return None
    try:
        for entry in os.listdir(parent_dir):
            full = os.path.join(parent_dir, entry)
            if os.path.isdir(full) and entry.lower() == target_name.lower():
                return full
    except Exception:
        pass
    return None

def resolve_paths():
    """Lazy discovery to dynamically find downloads, media, shows, and movies folders."""
    global DOWNLOADS_DIR, MEDIA_DIR, SHOWS_DIR, MOVIES_DIR

    # 1. Discover DOWNLOADS_DIR if not configured or missing
    if not DOWNLOADS_DIR or not os.path.isdir(DOWNLOADS_DIR):
        download_candidates = [
            DOWNLOADS_DIR,
            os.path.expanduser("~/Jellyfin/downloads/"),
            os.path.expanduser("~/downloads/"),
            os.path.expanduser("~/Downloads/"),
            "/volume*/home/*/Jellyfin/downloads/",
            "/volume*/Jellyfin/downloads/",
            "/volume*/downloads/",
            "/volume*/Downloads/",
            "/mnt/*/downloads/",
            "/media/downloads/",
            "/data/downloads/",
            "/downloads/",
        ]
        found_dl = discover_directory(download_candidates, "downloads")
        if found_dl:
            DOWNLOADS_DIR = found_dl
        elif not DOWNLOADS_DIR:
            DOWNLOADS_DIR = os.path.expanduser("~/Jellyfin/downloads/")

    # 2. Discover MEDIA_DIR if not configured or missing
    if not MEDIA_DIR or not os.path.isdir(MEDIA_DIR):
        media_candidates = [
            MEDIA_DIR,
            os.path.expanduser("~/Jellyfin/media/"),
            os.path.expanduser("~/media/"),
            os.path.expanduser("~/Media/"),
            "/volume*/home/*/Jellyfin/media/",
            "/volume*/Jellyfin/media/",
            "/volume*/media/",
            "/volume*/Media/",
            "/volume*/video/",
            "/mnt/*/media/",
            "/mnt/*/Media/",
            "/media/",
            "/data/media/",
        ]
        found_media = discover_directory(media_candidates, "media")
        if found_media:
            MEDIA_DIR = found_media
        elif not MEDIA_DIR:
            MEDIA_DIR = os.path.expanduser("~/Jellyfin/media/")

    # 3. Discover SHOWS_DIR
    if not SHOWS_DIR or not os.path.isdir(SHOWS_DIR):
        for name in ['Shows', 'TV Shows', 'TV', 'Series']:
            found = find_subfolder_ci(MEDIA_DIR, name)
            if found:
                SHOWS_DIR = found
                break

        if not SHOWS_DIR or not os.path.isdir(SHOWS_DIR):
            shows_candidates = [
                SHOWS_DIR,
                os.path.join(MEDIA_DIR, "Shows"),
                "/volume*/home/*/Jellyfin/media/Shows/",
                "/volume*/media/Shows/",
                "/volume*/media/TV Shows/",
                "/volume*/video/Shows/",
                "/mnt/*/media/Shows/",
                "/mnt/*/Shows/",
            ]
            found_shows = discover_directory(shows_candidates, "shows")
            SHOWS_DIR = found_shows if found_shows else os.path.join(MEDIA_DIR, "Shows")

    # 4. Discover MOVIES_DIR
    if not MOVIES_DIR or not os.path.isdir(MOVIES_DIR):
        for name in ['Movies', 'Films']:
            found = find_subfolder_ci(MEDIA_DIR, name)
            if found:
                MOVIES_DIR = found
                break

        if not MOVIES_DIR or not os.path.isdir(MOVIES_DIR):
            movies_candidates = [
                MOVIES_DIR,
                os.path.join(MEDIA_DIR, "Movies"),
                "/volume*/home/*/Jellyfin/media/Movies/",
                "/volume*/media/Movies/",
                "/volume*/video/Movies/",
                "/mnt/*/media/Movies/",
                "/mnt/*/Movies/",
            ]
            found_movies = discover_directory(movies_candidates, "movies")
            MOVIES_DIR = found_movies if found_movies else os.path.join(MEDIA_DIR, "Movies")

def load_config():
    global DOWNLOADS_DIR, MEDIA_DIR, SHOWS_DIR, MOVIES_DIR, CLEANUP_MODE, ARCHIVE_DIR, DOWNLOAD_SUBTITLES, SUBTITLE_LANGUAGES, SUBTITLE_DELAY
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
                    elif key == "SHOWS_DIR" and not SHOWS_DIR:
                        SHOWS_DIR = val
                    elif key == "MOVIES_DIR" and not MOVIES_DIR:
                        MOVIES_DIR = val
                    elif key == "CLEANUP_MODE" and not CLEANUP_MODE:
                        CLEANUP_MODE = val
                    elif key == "ARCHIVE_DIR" and not ARCHIVE_DIR:
                        ARCHIVE_DIR = val
                    elif key == "DOWNLOAD_SUBTITLES" and not DOWNLOAD_SUBTITLES:
                        DOWNLOAD_SUBTITLES = val
                    elif key == "SUBTITLE_LANGUAGES" and not SUBTITLE_LANGUAGES:
                        SUBTITLE_LANGUAGES = val
                    elif key == "SUBTITLE_DELAY":
                        try:
                            SUBTITLE_DELAY = float(val)
                        except ValueError:
                            pass

    # Run lazy auto-discovery for storage paths
    resolve_paths()

    # Fallback defaults for remaining settings
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

def fetch_subtitles(dest_path, media_type, info, show_name=None, s_num=None, e_num=None, movie_name=None, year=None):
    """Download subtitles using subliminal with User-Agent rotation and polite rate limiting."""
    if not SUBLIMINAL_AVAILABLE:
        print("  -> Subliminal library not installed, skipping subtitle download.")
        return

    if DOWNLOAD_SUBTITLES.lower() not in ("true", "1", "yes"):
        return

    dest_dir = os.path.dirname(dest_path)
    base_stem = os.path.splitext(os.path.basename(dest_path))[0]
    nosubs_marker = os.path.join(dest_dir, f"{base_stem}.nosubs")

    # Parse configured language codes into babelfish Language objects
    languages = set()
    for code in SUBTITLE_LANGUAGES.split(','):
        parsed = parse_language(code)
        if parsed:
            languages.add(parsed)
        else:
            print(f"  -> Warning: Could not parse language code '{code}'")

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
        # Subtitles exist — remove any stale marker if subs were manually added
        if os.path.exists(nosubs_marker):
            try:
                os.remove(nosubs_marker)
            except Exception:
                pass
        print(f"  -> Subtitles already exist for: {base_stem}")
        return

    # Skip querying if a previous run already verified that no subtitles were found
    if os.path.exists(nosubs_marker):
        print(f"  -> Skipping subtitle query (marked .nosubs from previous run): {base_stem}")
        return

    print(f"  -> Querying subtitle providers for: {base_stem} [{', '.join(l.alpha2 for l in missing_languages)}]...")

    query_succeeded = False
    found_any = False
    try:
        # Build Video object using subliminal's scan_video
        video = None
        try:
            video = scan_video(dest_path)
        except Exception:
            pass

        # Fallback to Episode.fromguess / Movie.fromguess
        if media_type == 'episode':
            if not isinstance(video, Episode):
                guess = {
                    'title': show_name,
                    'season': s_num,
                    'episode': e_num,
                    'type': 'episode'
                }
                if year:
                    guess['year'] = int(year) if str(year).isdigit() else year
                video = Episode.fromguess(dest_path, guess)
        else:
            if not isinstance(video, Movie):
                guess = {
                    'title': movie_name,
                    'type': 'movie'
                }
                if year:
                    guess['year'] = int(year) if str(year).isdigit() else year
                video = Movie.fromguess(dest_path, guess)

        # Download best matching subtitles
        subtitles = download_best_subtitles([video], missing_languages)
        query_succeeded = True
        if subtitles.get(video):
            saved = save_subtitles(video, subtitles[video], directory=dest_dir, language_format='alpha2')
            for s in saved:
                print(f"  [✓] Downloaded subtitle: {base_stem}.{s.language.alpha2}.srt")
                found_any = True
            if os.path.exists(nosubs_marker):
                try:
                    os.remove(nosubs_marker)
                except Exception:
                    pass
        else:
            print(f"  [-] No subtitles found from online providers for '{base_stem}'.")

    except Exception as e:
        print(f"  [!] Subtitle query encountered error (skipping gracefully): {e}")

    # If the search completed cleanly with 0 subtitles found, write a marker file
    # so future runs do not repeatedly query providers for missing items
    if query_succeeded and not found_any:
        try:
            import datetime
            with open(nosubs_marker, "w") as _f:
                _f.write(f"No subtitles found: {datetime.datetime.now().isoformat()}\n")
            print(f"  -> Created marker: {os.path.basename(nosubs_marker)}")
        except Exception:
            pass

    # Rate-limit delay between files to avoid triggering API throttling or HTTP 429
    if SUBTITLE_DELAY > 0:
        # Add slight jitter (e.g. 2.0s to 3.0s) so queries look natural to providers
        sleep_time = SUBTITLE_DELAY + random.uniform(0.2, 1.0)
        time.sleep(sleep_time)

def process_files():
    load_config()
    print(f"[+] Ingest downloads directory: {DOWNLOADS_DIR}")
    print(f"[+] TV Shows directory:         {SHOWS_DIR}")
    print(f"[+] Movies directory:           {MOVIES_DIR}")
    print(f"[+] Cleanup mode:               {CLEANUP_MODE}")
    if CLEANUP_MODE == 'move':
        print(f"[+] Archive directory:          {ARCHIVE_DIR}")
    print(f"[+] Download subtitles:         {DOWNLOAD_SUBTITLES} ({SUBTITLE_LANGUAGES})")
    print(f"[+] Rate-limit delay:           {SUBTITLE_DELAY}s between API requests")

    if not os.path.exists(DOWNLOADS_DIR):
        print(f"Downloads directory does not exist: {DOWNLOADS_DIR}")
        return

    os.makedirs(SHOWS_DIR, exist_ok=True)
    os.makedirs(MOVIES_DIR, exist_ok=True)

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
                    
                    dest_dir = os.path.join(SHOWS_DIR, show_name, season_folder)
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
                        print(f"Existing Show found: {clean_name}")
                        fetch_subtitles(dest_path, 'episode', info, show_name=show_name, s_num=s_num, e_num=e_num, year=year)

                # --- HANDLE MOVIES ---
                elif 'title' in info and info.get('type') == 'movie':
                    movie_name = str(info['title']).title()
                    year = info.get('year', '')
                    
                    # Create clean folder/file name: "Movie Name (2023)"
                    folder_name = f"{movie_name} ({year})" if year else movie_name
                    ext = os.path.splitext(file)[1]
                    clean_name = f"{folder_name}{ext}"
                    
                    dest_dir = os.path.join(MOVIES_DIR, folder_name)
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
                        print(f"Existing Movie found: {clean_name}")
                        fetch_subtitles(dest_path, 'movie', info, movie_name=movie_name, year=year)
                else:
                    # Log files that don't match movie/show patterns
                    print(f"Skipped (unrecognized format): {file}")

if __name__ == "__main__":
    process_files()
