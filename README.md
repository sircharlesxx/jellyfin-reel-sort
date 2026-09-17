# jellyfin-reel-sort

Automated synchronization, media organizing, subtitle downloading, and post-processing pipeline for Jellyfin libraries.

`jellyfin-reel-sort` provides an automated, lock-protected workflow to ingest downloads from a remote service (such as Put.io via `rclone`), parse media filenames, organize them into standardized Jellyfin-compatible directory structures using **hardlinks** (preserving disk space and original download paths), download matching subtitles, and handle optional post-sort cleanup.

---

## Architecture & How It Works

```mermaid
flowchart LR
    PutIO[Put.io / Cloud Remote] -->|rclone copy| Downloads[Downloads Folder]
    Downloads -->|sorter.py + guessit| Parser{TV or Movie?}
    Parser -->|Shows| TVDir["Shows/{Title}/Season XX/"]
    Parser -->|Movies| MovieDir["Movies/{Title} ({Year})/"]
    TVDir --> Subs["Download Subtitles (.en.srt)"]
    MovieDir --> Subs
    Subs -.->|Post-Sort Cleanup| Cleanup{"CLEANUP_MODE"}
    Cleanup -->|none| Seeding[Keep intact for seeding]
    Cleanup -->|delete| Remove[Delete source file]
    Cleanup -->|move| Archive["Archive Folder (processed/)"]
```

1. **`putsync.sh` (Sync Orchestrator)**:
   - Uses `flock` on a lockfile to prevent overlapping or concurrent runs.
   - Triggers `rclone copy` from remote (`put.io:/`) to the local staging folder (`DOWNLOADS_DIR`).
   - Logs execution progress and timestamps to the configured log file.
   - Automatically executes `sorter.py` immediately after transfer completion.

2. **`sorter.py` (Parser, Hardlinker, Subtitle Downloader & Cleanup Engine)**:
   - Recursively traverses `DOWNLOADS_DIR` searching for video containers (`.mkv`, `.mp4`, `.avi`).
   - Uses [guessit](https://github.com/guessit-io/guessit) to extract show title, season/episode numbers, movie title, and release year.
   - **TV Shows**: Formats into `Shows/<Show Name>/Season <XX>/<Show Name> - S<XX>E<YY>.<ext>`.
   - **Movies**: Formats into `Movies/<Movie Name> (<Year>)/<Movie Name> (<Year>).<ext>`.
   - Uses `os.link` to create **hardlinks** rather than moving or copying files:
     - Zero extra disk storage consumed.
     - Automatically skips files if the destination hardlink already exists.
   - **Automatic Subtitle Fetching**:
     - Uses [subliminal](https://github.com/Diaoul/subliminal) to query multiple subtitle providers (OpenSubtitles, Podnapisi, TVsubtitles, Gestdown, etc.).
     - Automatically detects if subtitles already exist beside the video to prevent duplicate downloads.
     - Formats subtitles according to Jellyfin naming conventions (e.g. `Show - S01E01.en.srt`, `Movie (2023).en.srt`).
     - Configurable language support (single or multiple languages comma-separated).
   - **Configurable Source Cleanup (`CLEANUP_MODE`)**:
     - `none` *(default)*: Keeps download source file intact (best for continuous torrent seeding/ratio).
     - `delete`: Deletes source file after hardlink and subtitle processing.
     - `move`: Moves source file to a separate archive directory (`ARCHIVE_DIR`).
   - Logs any skipped files that do not match recognizable movie or show patterns.

---

## Quick Installation

Run the interactive automated installer script:

```bash
git clone https://github.com/sircharlesxx/jellyfin-reel-sort.git
cd jellyfin-reel-sort
./install.sh
```

The installer will:
1. Verify / install `guessit` and `subliminal` via `pip`, and check for `rclone`.
2. Interactively prompt you for your custom storage paths and preferences:
   - Downloads / ingest staging directory
   - Jellyfin media library directory
   - Post-sort cleanup mode (`none`, `delete`, or `move`)
   - Archive directory (if `move` is chosen)
   - Enable/disable automatic subtitle downloads (`true` / `false`)
   - Subtitle languages (e.g. `en`, `es`, `fr`)
   - Rclone remote name (e.g. `put.io`)
   - Destination installation directory (default: `~/.local/bin`)
3. Write your custom configuration file (`~/.config/jellyfin-reel-sort.conf`).
4. Install executable scripts to your specified path.

---

## Project Structure

```text
jellyfin-reel-sort/
├── install.sh          # Interactive automated installer
├── putsync.sh          # Orchestration script with flock and rclone copy
├── sorter.py           # Media parsing, hardlinker, subtitle downloader & cleanup
├── .gitignore          # Ignores bytecode and cache files
└── README.md           # Documentation
```

---

## Configuration Reference

All settings can be customized in `~/.config/jellyfin-reel-sort.conf` (or via environment variables):

| Variable | Description | Default |
| :--- | :--- | :--- |
| `DOWNLOADS_DIR` | Ingest folder where downloads arrive | `~/Jellyfin/downloads/` |
| `MEDIA_DIR` | Base Jellyfin library folder containing `Shows/` and `Movies/` | `~/Jellyfin/media/` |
| `CLEANUP_MODE` | Post-linking source handling (`none`, `delete`, `move`) | `none` |
| `ARCHIVE_DIR` | Destination folder when `CLEANUP_MODE="move"` | `~/Jellyfin/processed/` |
| `DOWNLOAD_SUBTITLES` | Whether to automatically fetch subtitles (`true` / `false`) | `true` |
| `SUBTITLE_LANGUAGES` | Comma-separated language codes for subtitles | `en` |
| `REMOTE_NAME` | Rclone remote name configured for your cloud storage | `put.io` |
| `LOG_FILE` | Log output file for transfers and sorting | `~/.local/state/jellyfin-reel-sort/sync.log` |
| `LOCK_FILE` | Lockfile used by `flock` to prevent collisions | `/tmp/jellyfin_reel_sort.lock` |
| `SORTER_PATH` | Path to executable `sorter.py` | Installed script path |

---

## Subtitle Naming Structure for Jellyfin

Subtitles are automatically saved beside the media file following Jellyfin's recommended naming scheme:

```text
Shows/
  └── Breaking Bad/
      └── Season 01/
          ├── Breaking Bad - S01E01.mkv
          └── Breaking Bad - S01E01.en.srt

Movies/
  └── Inception (2010)/
      ├── Inception (2010).mkv
      └── Inception (2010).en.srt
```

---

## Manual Execution & Automation

### Run Manually
```bash
~/.local/bin/putsync.sh
```
Or run the hardlink sorter and subtitle downloader independently:
```bash
python3 ~/.local/bin/sorter.py
```

### Automation via Cron
To run every 30 minutes automatically, add this entry to `crontab -e`:

```cron
*/30 * * * * ~/.local/bin/putsync.sh >/dev/null 2>&1
```
*(The built-in `flock` ensures subsequent executions exit safely if a transfer is still ongoing).*

---

## Contributors & Acknowledgements

- **Charles Peters** ([@sircharlesxx](https://github.com/sircharlesxx)) - Project Creator & Maintainer
- **Kyle Keller** ([@kellerk563](https://github.com/kellerk563)) - Core Contributor: Designed and implemented the source cleanup pipeline (`delete` / `move` archival workflow) to manage extra and unwanted download files, along with unrecognized media pattern detection.
