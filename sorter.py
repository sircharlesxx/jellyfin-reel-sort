import os
import sys
import time
import random
import shutil
import glob
from guessit import guessit

# =============================================================================
# QUICK TOGGLE: Set to 0 to disable subtitle downloading entirely.
# The script will still sort and link all media normally — just skip subs.
# Set back to 1 when ready to re-enable.
# =============================================================================
ENABLE_SUBTITLES = 1

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
        from dogpile.cache import make_region
        _subliminal_region = make_region().configure('dogpile.cache.memory')

    # Silence noisy Subliminal/provider logs. Since we use 7 providers, it's completely normal 
    # for one (like opensubtitlescom) to occasionally return 400 Bad Request or 503. 
    # Subliminal safely catches these and tries the next provider, but by default it prints 
    # scary tracebacks to the console. We suppress them here.
    import logging
    logging.getLogger("subliminal").setLevel(logging.CRITICAL)

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
SUBTITLE_PROVIDERS = os.environ.get("SUBTITLE_PROVIDERS", "")  # comma-separated provider names, or empty for auto
SUBTITLE_DELAY = float(os.environ.get("SUBTITLE_DELAY", "2.0"))  # Seconds to wait between API calls to avoid rate limits
JELLYFIN_URL = os.environ.get("JELLYFIN_URL", "")  # Optional: e.g. http://localhost:8096 (auto-discovered if empty)
JELLYFIN_API_KEY = os.environ.get("JELLYFIN_API_KEY", "")  # Optional API key for triggering library scan on import

RESOLVED_PROVIDERS = None

def get_active_providers():
    """Resolve and return operational subtitle providers, filtering out dead domains like podnapisi.net."""
    global RESOLVED_PROVIDERS
    if RESOLVED_PROVIDERS is not None:
        return RESOLVED_PROVIDERS

    if not SUBLIMINAL_AVAILABLE:
        RESOLVED_PROVIDERS = []
        return RESOLVED_PROVIDERS

    import socket
    from urllib.parse import urlparse
    import subliminal.core

    # Standard providers supported in Subliminal's default pool
    default_pool = ['addic7ed', 'gestdown', 'napiprojekt', 'opensubtitles', 'opensubtitlescom', 'subtis', 'subtitulamos', 'tvsubtitles']
    available_names = list(subliminal.core.provider_manager.names())

    if SUBTITLE_PROVIDERS:
        candidates = [p.strip() for p in SUBTITLE_PROVIDERS.split(',') if p.strip() in available_names]
    else:
        # Exclude podnapisi by default since www.podnapisi.net has invalid/dead DNS records
        candidates = [p for p in default_pool if p in available_names and p != 'podnapisi']

    # Pre-flight HTTP check: ensure candidate hostnames resolve and respond
    # to avoid stalling subliminal if a provider (e.g. tvsubtitles) tarpits VPN IPs.
    import requests
    import urllib3
    from requests.adapters import HTTPAdapter
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
    
    # Use a raw session to bypass the global monkey-patch that adds retries
    with requests.Session() as test_session:
        # Override the patched adapter with a strict no-retry adapter
        no_retry_adapter = HTTPAdapter(max_retries=0)
        test_session.mount("http://", no_retry_adapter)
        test_session.mount("https://", no_retry_adapter)
        
        active = []
        for p_name in candidates:
            try:
                cls = subliminal.core.provider_manager[p_name].plugin
                url = getattr(cls, 'server_url', None)
                if url:
                    # Fast HTTP HEAD check (bypasses SSL cert issues so we just test connectivity)
                    test_session.head(url, timeout=2.5, verify=False, allow_redirects=True)
                active.append(p_name)
            except Exception as e:
                # Skip provider if DNS resolution or HTTP connection fails
                print(f"  [!] Provider '{p_name}' unreachable (skipping): {type(e).__name__}")
                continue

    RESOLVED_PROVIDERS = active
    return RESOLVED_PROVIDERS

DISCOVERED_JELLYFIN_URL = None

def discover_jellyfin_url():
    """Probe localhost and Docker port mappings to auto-discover a running Jellyfin instance."""
    global DISCOVERED_JELLYFIN_URL
    if DISCOVERED_JELLYFIN_URL is not None:
        return DISCOVERED_JELLYFIN_URL

    if JELLYFIN_URL:
        DISCOVERED_JELLYFIN_URL = JELLYFIN_URL.rstrip('/')
        return DISCOVERED_JELLYFIN_URL

    candidate_ports = [8096, 8920, 8080, 80]

    # Check docker inspect / docker ps if docker CLI is present
    try:
        import subprocess
        import re
        docker_out = subprocess.check_output(
            ["docker", "ps", "--format", "{{.Image}} {{.Ports}}"],
            stderr=subprocess.DEVNULL, timeout=2
        ).decode("utf-8")
        for line in docker_out.splitlines():
            if "jellyfin" in line.lower():
                matches = re.findall(r'0\.0\.0\.0:(\d+)->', line)
                for port_str in matches:
                    candidate_ports.insert(0, int(port_str))
    except Exception:
        pass

    import socket
    import urllib.request
    import json

    # Deduplicate candidate ports
    ports_to_check = []
    seen = set()
    for p in candidate_ports:
        if p not in seen:
            seen.add(p)
            ports_to_check.append(p)

    for port in ports_to_check:
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(0.3)
            res = s.connect_ex(('127.0.0.1', port))
            s.close()
            if res == 0:
                # Port is open; verify it is indeed Jellyfin via public info endpoint
                url = f"http://127.0.0.1:{port}/System/Info/Public"
                req = urllib.request.Request(url, headers={"User-Agent": "jellyfin-reel-sort"})
                with urllib.request.urlopen(req, timeout=1.0) as resp:
                    if resp.status == 200:
                        data = json.loads(resp.read().decode('utf-8'))
                        if "Jellyfin" in data.get("ProductName", ""):
                            DISCOVERED_JELLYFIN_URL = f"http://127.0.0.1:{port}"
                            return DISCOVERED_JELLYFIN_URL
        except Exception:
            continue

    DISCOVERED_JELLYFIN_URL = ""
    return DISCOVERED_JELLYFIN_URL

def trigger_jellyfin_refresh():
    """Trigger a Jellyfin library scan when new media or subtitles have been added."""
    url = discover_jellyfin_url()
    if not url:
        return

    if not JELLYFIN_API_KEY:
        print(f"[i] Jellyfin detected at {url}. Set JELLYFIN_API_KEY in config to enable automatic library refresh.")
        return

    print(f"[+] Notifying Jellyfin server at {url} to scan media libraries...")
    try:
        import urllib.request
        refresh_url = f"{url}/Library/Refresh"
        headers = {
            "User-Agent": "jellyfin-reel-sort",
            "Authorization": f'MediaBrowser Token="{JELLYFIN_API_KEY}"',
            "X-Emby-Token": JELLYFIN_API_KEY,
            "Content-Length": "0"
        }
        req = urllib.request.Request(refresh_url, method="POST", headers=headers)
        with urllib.request.urlopen(req, timeout=5.0) as resp:
            if resp.status in (200, 204):
                print("  [✓] Jellyfin library scan triggered successfully.")
            else:
                print(f"  [!] Jellyfin responded with HTTP status {resp.status}")
    except Exception as e:
        print(f"  [!] Failed to trigger Jellyfin library refresh: {e}")

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

def find_config_file():
    """Find configuration file across environment, /etc, or user home directories."""
    candidates = [
        os.environ.get("JELLYFIN_SORT_CONFIG"),
        "/etc/jellyfin-reel-sort.conf",
        os.path.expanduser("~/.config/jellyfin-reel-sort.conf"),
    ]
    for h in sorted(glob.glob("/home/*/.config/jellyfin-reel-sort.conf")):
        candidates.append(h)
    for c in candidates:
        if c and os.path.isfile(c):
            return c
    return None

def load_config():
    global DOWNLOADS_DIR, MEDIA_DIR, SHOWS_DIR, MOVIES_DIR, CLEANUP_MODE, ARCHIVE_DIR, DOWNLOAD_SUBTITLES, SUBTITLE_LANGUAGES, SUBTITLE_PROVIDERS, SUBTITLE_DELAY, JELLYFIN_URL, JELLYFIN_API_KEY
    cfg_file = find_config_file()
    if cfg_file and os.path.isfile(cfg_file):
        with open(cfg_file, "r") as f:
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
                    elif key == "SUBTITLE_PROVIDERS" and not SUBTITLE_PROVIDERS:
                        SUBTITLE_PROVIDERS = val
                    elif key == "SUBTITLE_DELAY":
                        try:
                            SUBTITLE_DELAY = float(val)
                        except ValueError:
                            pass
                    elif key == "JELLYFIN_URL" and not JELLYFIN_URL:
                        JELLYFIN_URL = val
                    elif key == "JELLYFIN_API_KEY" and not JELLYFIN_API_KEY:
                        JELLYFIN_API_KEY = val

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
            if os.path.exists(source_path):
                os.remove(source_path)
                print(f"  -> Deleted source: {source_path}")
                # Prune empty parent folders inside DOWNLOADS_DIR
                if DOWNLOADS_DIR and os.path.isdir(DOWNLOADS_DIR):
                    clean_downloads = os.path.realpath(DOWNLOADS_DIR)
                    parent = os.path.dirname(source_path)
                    while parent and os.path.realpath(parent) != clean_downloads:
                        try:
                            if os.path.isdir(parent) and not os.listdir(parent):
                                os.rmdir(parent)
                                print(f"  -> Pruned empty folder: {parent}")
                                parent = os.path.dirname(parent)
                            else:
                                break
                        except Exception:
                            break
        except Exception as e:
            print(f"  -> Warning: Failed to delete {source_path}: {e}")
            
    elif CLEANUP_MODE == 'move':
        try:
            if os.path.exists(source_path):
                os.makedirs(ARCHIVE_DIR, exist_ok=True)
                shutil.move(source_path, ARCHIVE_DIR)
                print(f"  -> Moved source to archive: {source_path}")
        except Exception as e:
            print(f"  -> Warning: Failed to move {source_path}: {e}")

def prune_downloads_directory():
    """When CLEANUP_MODE is 'delete', remove leftover non-media clutter (.txt, .nfo, posters, etc.)
    and prune empty folders in DOWNLOADS_DIR once all media files have been processed."""
    if CLEANUP_MODE != 'delete' or not DOWNLOADS_DIR or not os.path.isdir(DOWNLOADS_DIR):
        return

    MEDIA_EXTS = ('.mkv', '.mp4', '.avi')
    CLUTTER_EXTS = (
        '.txt', '.nfo', '.url', '.website', '.html', '.htm',
        '.jpg', '.jpeg', '.png', '.gif', '.sfv', '.md',
        '.idx', '.sub', '.srt', '.vtt'
    )

    clean_dl = os.path.realpath(DOWNLOADS_DIR)

    # Walk bottom-up so leaf directories are cleaned and pruned before their parents
    for root, dirs, files in os.walk(DOWNLOADS_DIR, topdown=False):
        if os.path.realpath(root) == clean_dl:
            continue

        # Check if this folder or any of its subfolders still contain media files
        has_media = False
        for r, _, fs in os.walk(root):
            if any(f.lower().endswith(MEDIA_EXTS) for f in fs):
                has_media = True
                break

        if not has_media:
            # All media in this folder has been processed/deleted; clean up remaining clutter
            for f in files:
                if f.lower().endswith(CLUTTER_EXTS):
                    file_path = os.path.join(root, f)
                    try:
                        os.remove(file_path)
                        print(f"  -> Deleted leftover file: {f}")
                    except Exception:
                        pass

            # Prune directory if now empty
            try:
                if not os.listdir(root):
                    os.rmdir(root)
                    print(f"  -> Pruned empty folder: {root}")
            except Exception:
                pass

def sanitize_srt_file(filepath):
    """Clean and standardize an SRT file: strip BOM, ensure UTF-8, normalize CRLF line endings.

    Jellyfin uses Nikse.SubtitleEdit (SubRip parser) to parse .srt files. If an SRT file
    starts with a UTF-8 Byte Order Mark (\xef\xbb\xbf or \ufeff), int.TryParse fails on line 1,
    causing the entire subtitle file to be rejected as empty/invalid while still appearing
    in the Closed Captions selection menu.
    """
    try:
        if not os.path.isfile(filepath):
            return False

        with open(filepath, 'rb') as f:
            raw = f.read()

        if not raw:
            return False

        needs_fix = False

        # Detect and strip byte-level BOMs
        if raw.startswith(b'\xef\xbb\xbf'):
            raw = raw[3:]
            needs_fix = True
        elif raw.startswith(b'\xff\xfe'):
            raw = raw.decode('utf-16-le', errors='replace').encode('utf-8')
            needs_fix = True
        elif raw.startswith(b'\xfe\xff'):
            raw = raw.decode('utf-16-be', errors='replace').encode('utf-8')
            needs_fix = True

        # Decode text safely
        text = None
        for enc in ('utf-8', 'cp1252', 'latin-1'):
            try:
                text = raw.decode(enc)
                break
            except UnicodeDecodeError:
                continue

        if not text:
            text = raw.decode('utf-8', errors='replace')
            needs_fix = True

        # Strip any leading Unicode BOM (\ufeff) or stray whitespace
        if text.startswith('\ufeff'):
            text = text.lstrip('\ufeff')
            needs_fix = True

        # Check line endings: SubRip standard is CRLF (\r\n)
        if '\r\n' not in text and '\n' in text:
            needs_fix = True

        # Always ensure proper 0644 permissions for Docker Jellyfin
        try:
            os.chmod(filepath, 0o644)
        except Exception:
            pass

        if not needs_fix:
            return False

        # Clean lines and normalize to CRLF
        lines = [line.rstrip('\r\n') for line in text.split('\n')]
        clean_content = '\r\n'.join(lines).strip() + '\r\n'

        with open(filepath, 'wb') as f:
            f.write(clean_content.encode('utf-8'))

        return True
    except Exception as e:
        print(f"  [!] Failed to sanitize SRT {filepath}: {e}")
        return False


def sanitize_all_existing_subtitles():
    """Scan SHOWS_DIR and MOVIES_DIR to fix any existing .srt files in-place."""
    dirs_to_check = [d for d in (SHOWS_DIR, MOVIES_DIR) if d and os.path.isdir(d)]
    if not dirs_to_check:
        return

    fixed = 0
    for base_dir in dirs_to_check:
        for root, _, files in os.walk(base_dir):
            for f in files:
                if f.lower().endswith('.srt'):
                    full_path = os.path.join(root, f)
                    if sanitize_srt_file(full_path):
                        fixed += 1

    if fixed > 0:
        print(f"[+] Subtitle sanitizer: Repaired {fixed} existing subtitle file(s) (stripped BOM / normalized CRLF).")


def find_accompanying_subtitles(root, video_file, s_num=None, e_num=None):
    """Find subtitle files already packaged with the download in root or a Subs/ subfolder."""
    import re
    base_name = os.path.splitext(video_file)[0]

    # 1. Exact base name match in the same folder
    for ext in ('.srt', '.en.srt', '.eng.srt', '.vtt'):
        candidate = os.path.join(root, f"{base_name}{ext}")
        if os.path.isfile(candidate):
            return candidate

    # 2. Check all .srt files in root and immediate subfolders (Subs, Subtitles)
    search_dirs = [root]
    for sub in ('Subs', 'subs', 'Subtitles', 'subtitles'):
        sub_dir = os.path.join(root, sub)
        if os.path.isdir(sub_dir):
            search_dirs.append(sub_dir)

    all_srts = []
    for d in search_dirs:
        try:
            for f in os.listdir(d):
                if f.lower().endswith(('.srt', '.vtt')):
                    all_srts.append(os.path.join(d, f))
        except Exception:
            pass

    # For TV episodes: look for SxxExx match
    if s_num is not None and e_num is not None:
        patterns = [
            rf'[sS]{s_num:02d}[eE]{e_num:02d}',
            rf'{s_num}x{e_num:02d}',
            rf'{s_num}x{e_num}',
        ]
        for srt_path in all_srts:
            filename = os.path.basename(srt_path)
            if any(re.search(p, filename) for p in patterns):
                if 'eng' in filename.lower() or 'en.' in filename.lower() or not any(l in filename.lower() for l in ('spa', 'fre', 'ger', 'ita', 'rus', 'por', 'chi', 'jpn')):
                    return srt_path
        return None

    # For Movies: if single movie in folder, pick English or only srt
    for srt_path in all_srts:
        fn = os.path.basename(srt_path).lower()
        if any(w in fn for w in ('eng', 'english', '.en.')):
            return srt_path

    if len(all_srts) == 1:
        return all_srts[0]

    return None


def _get_missing_languages(dest_dir, base_stem, languages):
    """Return the subset of languages that don't already have a subtitle file on disk."""
    missing = set()
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
            f"{base_stem}.srt",
        ]
        if not any(os.path.exists(os.path.join(dest_dir, c)) for c in existing):
            missing.add(lang)
    return missing


def _build_video_object(dest_path, media_type, info,
                        show_name=None, s_num=None, e_num=None,
                        movie_name=None, year=None,
                        original_filename=None):
    """Build a subliminal Video object for a media file, preserving release group info for accurate scoring."""
    video = None
    try:
        video = scan_video(dest_path, name=original_filename)
    except Exception:
        pass

    if media_type == 'episode':
        if not isinstance(video, Episode):
            guess = dict(info) if info else {}
            guess.update({'title': show_name, 'season': s_num, 'episode': e_num, 'type': 'episode'})
            if year:
                guess['year'] = int(year) if str(year).isdigit() else year
            video = Episode.fromguess(dest_path, guess)
    else:
        if not isinstance(video, Movie):
            guess = dict(info) if info else {}
            guess.update({'title': movie_name, 'type': 'movie'})
            if year:
                guess['year'] = int(year) if str(year).isdigit() else year
            video = Movie.fromguess(dest_path, guess)

    return video


def batch_fetch_subtitles(pending):
    """
    Download subtitles for a batch of media files in a single provider session.

    This is the key optimization: subliminal's ProviderPool (used internally by
    download_best_subtitles) opens one HTTP session per provider for the entire
    batch, rather than opening and closing a session for every individual file.
    For a 50-file run, this reduces tvsubtitles/addic7ed connections from 50 to 1.

    pending: list of dicts with keys:
        dest_path, media_type, info, show_name, s_num, e_num, movie_name, year
    Returns: int — total subtitle files saved
    """
    if not ENABLE_SUBTITLES:
        return 0
    if not SUBLIMINAL_AVAILABLE:
        return 0
    if DOWNLOAD_SUBTITLES.lower() not in ("true", "1", "yes"):
        return 0
    if not pending:
        return 0

    import datetime

    # Parse configured languages once
    languages = set()
    for code in SUBTITLE_LANGUAGES.split(','):
        parsed = parse_language(code)
        if parsed:
            languages.add(parsed)
    if not languages:
        return 0

    # --- Pre-flight filter (no network, pure disk checks) ---
    # Remove files that already have subs or are marked .nosubs
    # so we never even build a Video object for them.
    queue = []  # (Video, dest_dir, base_stem, nosubs_marker)
    for item in pending:
        dest_path  = item['dest_path']
        dest_dir   = os.path.dirname(dest_path)
        base_stem  = os.path.splitext(os.path.basename(dest_path))[0]
        nosubs_marker = os.path.join(dest_dir, f"{base_stem}.nosubs")

        missing = _get_missing_languages(dest_dir, base_stem, languages)

        if not missing:
            # Subs already present — clear any stale .nosubs marker
            if os.path.exists(nosubs_marker):
                try:
                    os.remove(nosubs_marker)
                except Exception:
                    pass
            print(f"  -> Subtitles already exist for: {base_stem}")
            continue

        if os.path.exists(nosubs_marker):
            # Expire .nosubs markers after 3 days so we eventually retry
            # in case new subs were uploaded or VPN blocks cleared up
            mtime = os.path.getmtime(nosubs_marker)
            if time.time() - mtime > 86400 * 3:
                try:
                    os.remove(nosubs_marker)
                except Exception:
                    pass
            else:
                print(f"  -> Skipping (marked .nosubs from previous run): {base_stem}")
                continue

        # Build Video object (local disk operation, no network)
        try:
            video = _build_video_object(
                dest_path,
                item['media_type'],
                item['info'],
                show_name  = item.get('show_name'),
                s_num      = item.get('s_num'),
                e_num      = item.get('e_num'),
                movie_name = item.get('movie_name'),
                year       = item.get('year'),
                original_filename = item.get('original_filename'),
            )
        except Exception as e:
            print(f"  [!] Could not build video object for {base_stem}: {e}")
            continue

        queue.append((video, dest_dir, base_stem, nosubs_marker))

    if not queue:
        return 0

    active_providers = get_active_providers()
    chunk_size = 10
    total_saved = 0

    print(f"\n[+] Querying subtitle providers for {len(queue)} file(s) in chunks of {chunk_size}...")
    print(f"    Providers: {', '.join(active_providers)}")

    for i in range(0, len(queue), chunk_size):
        chunk = queue[i:i + chunk_size]
        video_objects = [entry[0] for entry in chunk]
        
        print(f"\n  -> Processing chunk {i//chunk_size + 1}/{(len(queue) + chunk_size - 1)//chunk_size} ({len(chunk)} files)...")
        
        chunk_subtitles = {}
        query_succeeded = False
        try:
            chunk_subtitles = download_best_subtitles(
                video_objects,
                languages,
                providers=active_providers,
            )
            query_succeeded = True
        except Exception as e:
            print(f"  [!] Chunk subtitle query error: {e}")

        # Save results and write .nosubs markers for this chunk
        for video, dest_dir, base_stem, nosubs_marker in chunk:
            subs = chunk_subtitles.get(video, [])
            if subs:
                try:
                    # Enforce UTF-8 encoding and fix permissions to ensure Jellyfin can read and render them properly
                    saved = save_subtitles(video, subs, directory=dest_dir, encoding='utf-8', language_format='alpha2')
                    for s in saved:
                        sub_name = f"{base_stem}.{s.language.alpha2}.srt"
                        sub_path = os.path.join(dest_dir, sub_name)
                        if os.path.exists(sub_path):
                            sanitize_srt_file(sub_path)
                        print(f"    [✓] Saved: {sub_name}")
                    total_saved += len(saved)
                    # Clear any stale .nosubs marker
                    if os.path.exists(nosubs_marker):
                        try:
                            os.remove(nosubs_marker)
                        except Exception:
                            pass
                except Exception as e:
                    print(f"    [!] Failed to save subtitle for {base_stem}: {e}")
            elif query_succeeded:
                # Search ran cleanly but found nothing — write .nosubs marker
                print(f"    [-] No subtitles found for: {base_stem}")
                try:
                    with open(nosubs_marker, 'w') as _f:
                        _f.write(f"No subtitles found: {datetime.datetime.now().isoformat()}\n")
                except Exception:
                    pass
            else:
                # Query itself errored — do NOT write .nosubs so we retry next run
                print(f"    [?] Subtitle status unknown (query error) for: {base_stem}")

        # Polite delay between chunks
        if i + chunk_size < len(queue):
            time.sleep(2.0)

    return total_saved


def process_files():
    load_config()
    print(f"[+] Ingest downloads directory: {DOWNLOADS_DIR}")
    print(f"[+] TV Shows directory:         {SHOWS_DIR}")
    print(f"[+] Movies directory:           {MOVIES_DIR}")
    print(f"[+] Cleanup mode:               {CLEANUP_MODE}")
    if CLEANUP_MODE == 'move':
        print(f"[+] Archive directory:          {ARCHIVE_DIR}")
    print(f"[+] Download subtitles:         {DOWNLOAD_SUBTITLES} ({SUBTITLE_LANGUAGES})")
    providers = get_active_providers()
    print(f"[+] Subtitle providers:         {', '.join(providers) if providers else 'None'}")

    discovered_jf = discover_jellyfin_url()
    if discovered_jf:
        status_note = f"{discovered_jf} (API auto-refresh {'enabled' if JELLYFIN_API_KEY else 'idle - no API key set'})"
    else:
        status_note = "Not detected on localhost"
    print(f"[+] Jellyfin instance:          {status_note}")

    if not os.path.exists(DOWNLOADS_DIR):
        print(f"Downloads directory does not exist: {DOWNLOADS_DIR}")
        return

    os.makedirs(SHOWS_DIR, exist_ok=True)
    os.makedirs(MOVIES_DIR, exist_ok=True)

    # Automatically sanitize all existing .srt files in media directories
    # (strips UTF-8 BOM, fixes CRLF line endings, ensures 0644 permissions)
    if ENABLE_SUBTITLES:
        sanitize_all_existing_subtitles()

    new_media_linked = 0
    subtitle_pending = []  # collect all files needing subtitle lookup

    # --- Phase 1: Link all media files (no network I/O) ---
    for root, dirs, files in os.walk(DOWNLOADS_DIR):
        for file in files:
            if not file.endswith(('.mkv', '.mp4', '.avi')):
                continue

            source_path = os.path.join(root, file)
            info = guessit(file)
            # If the filename itself lacks a title (e.g. S01E01.mkv inside a named folder),
            # re-run guessit with the relative path to extract title from parent directories
            if 'title' not in info or ('season' not in info and 'episode' not in info and info.get('type') != 'movie'):
                rel_path = os.path.relpath(source_path, DOWNLOADS_DIR)
                rel_info = guessit(rel_path)
                if 'title' in rel_info:
                    info = rel_info

            # TV SHOW
            if 'title' in info and 'season' in info and 'episode' in info:
                show_name   = str(info['title']).title()
                s_num       = info['season'][0]  if isinstance(info['season'],   list) else info['season']
                e_num       = info['episode'][0] if isinstance(info['episode'],  list) else info['episode']
                year        = info.get('year')
                season_folder = f"Season {s_num:02d}"
                ext         = os.path.splitext(file)[1]
                clean_name  = f"{show_name} - S{s_num:02d}E{e_num:02d}{ext}"
                dest_dir    = os.path.join(SHOWS_DIR, show_name, season_folder)
                dest_path   = os.path.join(dest_dir, clean_name)

                os.makedirs(dest_dir, exist_ok=True)
                if not os.path.exists(dest_path):
                    try:
                        os.link(source_path, dest_path)
                        print(f"Linked Show: {clean_name}")
                        new_media_linked += 1
                        cleanup_source(source_path)
                    except Exception as e:
                        print(f"Error linking {file}: {e}")
                        continue
                else:
                    print(f"Existing Show: {clean_name}")
                    if CLEANUP_MODE in ('delete', 'move'):
                        cleanup_source(source_path)

                # Check if download package already included a matching subtitle
                inc_sub = find_accompanying_subtitles(root, file, s_num=s_num, e_num=e_num)
                if inc_sub:
                    dest_sub = os.path.join(dest_dir, f"{show_name} - S{s_num:02d}E{e_num:02d}.en.srt")
                    if not os.path.exists(dest_sub):
                        try:
                            try:
                                os.link(inc_sub, dest_sub)
                            except Exception:
                                shutil.copy2(inc_sub, dest_sub)
                            sanitize_srt_file(dest_sub)
                            print(f"  [✓] Linked included subtitle: {os.path.basename(dest_sub)}")
                            cleanup_source(inc_sub)
                        except Exception as e:
                            print(f"  [!] Failed to link included subtitle: {e}")
                    else:
                        if CLEANUP_MODE in ('delete', 'move'):
                            cleanup_source(inc_sub)

                subtitle_pending.append({
                    'dest_path': dest_path, 'media_type': 'episode', 'info': info,
                    'show_name': show_name, 's_num': s_num, 'e_num': e_num, 'year': year,
                    'original_filename': file,
                })

            # MOVIE
            elif 'title' in info and info.get('type') == 'movie':
                movie_name  = str(info['title']).title()
                year        = info.get('year', '')
                folder_name = f"{movie_name} ({year})" if year else movie_name
                ext         = os.path.splitext(file)[1]
                clean_name  = f"{folder_name}{ext}"
                dest_dir    = os.path.join(MOVIES_DIR, folder_name)
                dest_path   = os.path.join(dest_dir, clean_name)

                os.makedirs(dest_dir, exist_ok=True)
                if not os.path.exists(dest_path):
                    try:
                        os.link(source_path, dest_path)
                        print(f"Linked Movie: {clean_name}")
                        new_media_linked += 1
                        cleanup_source(source_path)
                    except Exception as e:
                        print(f"Error linking {file}: {e}")
                        continue
                else:
                    print(f"Existing Movie: {clean_name}")
                    if CLEANUP_MODE in ('delete', 'move'):
                        cleanup_source(source_path)

                # Check if download package already included a matching subtitle
                inc_sub = find_accompanying_subtitles(root, file)
                if inc_sub:
                    dest_sub = os.path.join(dest_dir, f"{folder_name}.en.srt")
                    if not os.path.exists(dest_sub):
                        try:
                            try:
                                os.link(inc_sub, dest_sub)
                            except Exception:
                                shutil.copy2(inc_sub, dest_sub)
                            sanitize_srt_file(dest_sub)
                            print(f"  [✓] Linked included subtitle: {os.path.basename(dest_sub)}")
                            cleanup_source(inc_sub)
                        except Exception as e:
                            print(f"  [!] Failed to link included subtitle: {e}")
                    else:
                        if CLEANUP_MODE in ('delete', 'move'):
                            cleanup_source(inc_sub)

                subtitle_pending.append({
                    'dest_path': dest_path, 'media_type': 'movie', 'info': info,
                    'movie_name': movie_name, 'year': year,
                    'original_filename': file,
                })

            else:
                print(f"Skipped (unrecognized format): {file}")

    # --- Phase 2: Batch subtitle download (single provider session for ALL files) ---
    new_subs_downloaded = batch_fetch_subtitles(subtitle_pending)

    # Clean up leftover clutter files (.txt, .nfo, images) and empty directories
    prune_downloads_directory()

    if new_media_linked > 0 or new_subs_downloaded > 0:
        print(f"\n[+] Sort summary: {new_media_linked} new media linked, {new_subs_downloaded} new subtitles downloaded.")
        trigger_jellyfin_refresh()
    else:
        print("\n[+] Sort summary: No new media or subtitles added.")

if __name__ == "__main__":
    process_files()

