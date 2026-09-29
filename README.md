<div align="center">
  <h1>🎬 Jellyfin Reel Sort</h1>
  <p><b>Your personal, automated media butler for Jellyfin!</b></p>

  <p>
    <img src="https://img.shields.io/badge/Bash-4EAA25?style=for-the-badge&logo=gnu-bash&logoColor=white" alt="Bash" />
    <img src="https://img.shields.io/badge/Python-3776AB?style=for-the-badge&logo=python&logoColor=white" alt="Python" />
    <img src="https://img.shields.io/badge/Jellyfin-00A4DC?style=for-the-badge&logo=jellyfin&logoColor=white" alt="Jellyfin" />
  </p>
</div>

---

## 👋 Welcome to Jellyfin Reel Sort!

Imagine having a magic assistant that constantly checks your cloud storage, downloads new movies and TV shows at lightning speed, organizes them perfectly for Jellyfin, and cleans up the mess—all without using up double the space on your hard drive! 

That's exactly what **Jellyfin Reel Sort** does. 🍿

---

## 🚀 How It Works (The Simple Version)

Here is the journey of your media, from the cloud directly to your TV screen:

```text
☁️ Cloud Storage / Remote Server
       │
       ▼  (1. Downloads)
       │
📥 Downloads Folder
       │
       ▼  (2. Sorts & Links)
       │
🪄 Reel Sort Magic
       ├──► 📺 TV Shows Folder ──► 🍿 Jellyfin Server
       └──► 🎬 Movies Folder   ──► 🍿 Jellyfin Server
```

1. **Downloads:** We securely pull your files from the cloud to your local `downloads` folder.
2. **Sorts & Links:** We magically link the files into beautiful, organized folders for Jellyfin (`Movies/` and `Shows/`). 
3. **Enjoy:** We tap Jellyfin on the shoulder to let it know new stuff is ready to watch!

---

## 🤯 Hardlinking: The Backbone of Large Libraries

When managing a massive media library, you often run into a direct conflict between your ingest pipeline and your media server:
1. **Ingest clients** (cloud sync tools or torrent clients) need files to remain in their original, messy release formats (e.g., `Movie.2024.1080p.WEB-DL.x264-GRP.mkv`) in the `downloads/` directory to continue seeding or to prevent re-downloading.
2. **Jellyfin** requires pristine, standardized folder structures (e.g., `Movies/My Movie (2024)/My Movie (2024).mkv`) to reliably scrape metadata, fetch subtitles, and organize cast information.

Reel Sort bridges this gap natively using filesystem **Hardlinks**.

```text
                  [ Your Hard Drive ]
                 📀 Target Video Inode
                      ▲       ▲
         (Points to)  │       │  (Points to)
                      │       │
📂 downloads/Release_Name.mkv     📂 Movies/Clean Name (2024).mkv
```

- 🤝 **Preserves Sync & Seed State:** The original file remains untouched in the `downloads/` directory. Auto-sync scripts and torrent clients instantly recognize the file is present and intact.
- ✨ **Pristine Library Metadata:** Jellyfin receives a perfectly named and sorted file structure, guaranteeing accurate metadata matching and a beautiful UI, without ever altering the raw download.
- ⚡ **Instantaneous & I/O Free:** Creating a hardlink happens at the filesystem level in milliseconds. There is zero disk I/O overhead, allowing you to ingest massive 4K libraries instantly.

---

## ⚡ Supercharged Downloading (Built for Modern Networks)

Why download files normally when you can download them *faster* and *safer*? We've engineered the sync pipeline to maximize throughput on any connection—whether you are on gigabit fiber, a flaky cellular network, or standard home broadband.

- **The Need for Speed (Parallel Multi-Streaming):** Standard downloads pull a file sequentially over a single TCP connection, which often fails to saturate high-bandwidth links due to window sizing limits or carrier-level traffic shaping. To solve this, we utilize **concurrent HTTP Range requests**. By splitting large media files and opening 4 parallel streams simultaneously, we force network load balancers and carriers to allocate maximum available bandwidth, allowing you to easily saturate gigabit fiber or 5G Ultra Wideband links.
- **The Need for Safety (Checkpointing):** Have you ever downloaded 99% of a huge 4K movie, only for the internet to drop and lose everything? We designed Reel Sort to download exactly **1 file at a time**. Once a file finishes, it is permanently locked in. If the power goes out or the connection drops, the script simply resumes from the next file. No wasted bandwidth, no lost progress.

---

## 🛠️ Your Magic Wand Toolkit

Once installed, these easy commands are available to use from anywhere on your server!

| Command | What it does |
| :--- | :--- |
| ⚡ `putsync.sh` | **The Auto-Sync:** Checks the cloud, downloads new stuff, sorts it, and tells Jellyfin. Run this on a schedule! |
| 🎯 `get_movie.sh` | **The Quick Grab:** Search your cloud for a specific movie and download it right now. |
| 📦 `initial-import.sh` | **The Organizer:** Already have a messy folder of downloads? This instantly sorts and links them all into Jellyfin. |
| 🗑️ `delete.sh` | **The Janitor:** Easily delete a movie from Jellyfin, your hard drive, AND the cloud all at once to save space. |
| 🐳 `jellyfin-docker-setup.sh` | **The Installer:** Quickly setup or reset a pristine Jellyfin server using Docker. |

> 💡 **Tip:** We automatically create shortcuts for you, so you can just type `get_movie.sh` anywhere without navigating to a specific folder!

---

## 🏃‍♂️ Fresh Installation (Start Here)

Run these steps once on your NAS or Linux server to get everything set up from scratch.

### Step 1 — Clone the repo

```bash
cd /home/mariofishy
git clone https://github.com/sircharlesxx/jellyfin-reel-sort.git
cd jellyfin-reel-sort
```

Everything lives in this folder. Future updates are just `git pull` from inside it.

### Step 2 — Configure your environment

```bash
cp .env.example .env
nano .env
```

Fill in your values:

```bash
# Find your UID and GID
id mariofishy
# → uid=1000(mariofishy) gid=1000(mariofishy)
```

```env
PUID=1000          # your UID from above
PGID=1000          # your GID from above
TZ=America/Chicago # your timezone
```

Leave the path variables as-is unless your layout differs from the defaults.

### Step 3 — Install the Intel QuickSync driver

Required for hardware transcoding. Skip if you don't have an Intel CPU/iGPU.

```bash
sudo apt install intel-media-va-driver-non-free

# Confirm the render device exists
ls -la /dev/dri/
# You should see: renderD128
```

### Step 4 — Start Jellyfin

```bash
docker compose up -d
```

Jellyfin is now running. Open **http://\<your-nas-ip\>:8096** in a browser.

### Step 5 — Complete the Jellyfin setup wizard

When the wizard asks to add media libraries, use these paths:

| Library | Path to add |
|:---|:---|
| Movies | `/media/Movies` |
| TV Shows | `/media/Shows` |

### Step 6 — Enable Intel QuickSync in Jellyfin

Go to **Dashboard → Playback → Transcoding**:
- Hardware acceleration: **Video Acceleration API (VAAPI)**
- VAApi Device: `/dev/dri/renderD128`
- ✅ Check "Enable hardware encoding"
- Save

### Step 7 — Set up the auto-sync cron job

This runs the cloud sync every 5 minutes automatically. Run as root:

```bash
sudo crontab -e
```

Add this line at the bottom:

```cron
*/5 * * * * /home/mariofishy/jellyfin-reel-sort/putsync.sh >/dev/null 2>&1
```

### Step 8 — Configure rclone for your cloud storage

```bash
rclone config
```

Follow the prompts to connect your cloud remote. The default remote name expected by this project is `put.io` — if yours is different, add `REMOTE_NAME=yourremotename` to your config file at `~/.config/jellyfin-reel-sort.conf`.

### Step 9 — Grab your Jellyfin API key (optional but recommended)

An API key allows the sync script to automatically trigger a Jellyfin library scan after each download.

1. Go to **Dashboard → API Keys** → **+**
2. Name it anything (e.g. `putsync`)
3. Copy the key and add it to `~/.config/jellyfin-reel-sort.conf`:

```bash
echo 'JELLYFIN_API_KEY="your-key-here"' >> ~/.config/jellyfin-reel-sort.conf
```

### Updating in the future

```bash
cd /home/mariofishy/jellyfin-reel-sort
git pull
```

That's it. The cron always runs directly from this folder so updates take effect immediately.

---

## 🐳 Docker Compose Setup (Recommended)

The included [`docker-compose.yml`](docker-compose.yml) starts a fully configured Jellyfin server with Intel QuickSync hardware transcoding.

### 1. Set your environment

```bash
cd jellyfin-reel-sort
cp .env.example .env
nano .env
```

Fill in your user's UID, GID, and timezone:

```bash
# Find your UID and GID
id mariofishy
# → uid=1000(mariofishy) gid=1000(mariofishy) ...
```

### 2. Install the Intel QuickSync VAAPI driver on the host

Without this, Jellyfin cannot use the GPU for transcoding:

```bash
# Ubuntu / Debian
sudo apt install intel-media-va-driver-non-free

# Verify the render device exists
ls -la /dev/dri/
# → You should see renderD128 (and card0)
```

### 3. Start Jellyfin

```bash
docker compose up -d
```

Open **http://\<your-nas-ip\>:8096** and follow the setup wizard.

### 4. Add your media libraries

When prompted to add libraries, use these container-internal paths:

| Library type | Path |
|:---|:---|
| TV Shows | `/media/Shows` |
| Movies | `/media/Movies` |

### 5. Enable Intel QuickSync in Jellyfin

Go to **Dashboard → Playback → Transcoding**:

- Hardware acceleration: **Video Acceleration API (VAAPI)**
- VAApi Device: `/dev/dri/renderD128`
- ✅ Enable hardware encoding

### Directory layout expected by Docker Compose

```text
~/media/                    ← mounted as /media (read-only inside container)
  ├── Movies/
  │     └── My Movie (2024)/
  └── Shows/
        └── My Show/

~/Jellyfin/
  ├── config/               ← Jellyfin database & settings (persistent)
  ├── cache/                ← Thumbnails & transcode cache (safe to delete)
  └── downloads/            ← Raw cloud downloads (sorter.py hardlinks to ~/media)
```

> **Why `~/media` and `~/Jellyfin/downloads` must stay on the same partition:**
> Hardlinks work at the filesystem block level. The sorter.py script creates a hardlink from a file in `downloads/` into `media/` — which means both paths point to the **same physical data on disk** with zero duplication. If they were on different partitions, hardlinks would be impossible and you'd need 2× disk space.

### Render group permission errors?

If Jellyfin logs `Permission denied opening /dev/dri/renderD128`, find your render group GID and set it explicitly:

```bash
stat -c %G /dev/dri/renderD128
# → e.g. 105
```

Edit `docker-compose.yml` and change:
```yaml
group_add:
  - "105"   # replace "render" with your actual GID
```

---

## 📖 Everyday Cheat Sheet

Here are the most common things you might want to do:

### 1. "I want to download a specific movie right now!"
Just type this and follow the prompts:
```bash
get_movie.sh
```

### 2. "I want it to automatically sync every 5 minutes!"
You can tell your server to run the sync automatically using a `cron` schedule. 

Type `crontab -e` in your terminal, and add this line at the bottom:
```cron
*/5 * * * * ~/.local/bin/putsync.sh >/dev/null 2>&1
```

### 3. "My hard drive is full, I need to delete some stuff!"
Run the cleaner to remove media everywhere at once:
```bash
delete.sh
```
> **What the Magic Janitor does behind the scenes:**  
> If you just delete a movie inside the Jellyfin app, the original massive file is still hiding in your `downloads/` folder eating space, and your cloud sync might redownload it! `delete.sh` fixes this by:
> 1. Giving you an interactive menu to browse/search your library.
> 2. Finding both the perfectly named `media/` file and the messy original `downloads/` file.
> 3. Calculating exactly how much space you'll reclaim.
> 4. Deleting local files and (optionally) purging it from your cloud storage.
> 5. Automatically pinging Jellyfin so it instantly disappears from your screen.

### 4. "I already have a bunch of downloads, organize them!"
```bash
initial-import.sh --fast
```

---

## 🛡️ Long Downloads & Reliability

Reel Sort is designed to handle very large files and long overnight downloads without supervision. Here's exactly how it protects you.

---

### 🔒 The Lock File: No Two Downloads at Once

Every time `putsync.sh` or `get_movie.sh` starts a download, it acquires an **exclusive kernel-level lock** at `/tmp/jellyfin_reel_sort.lock` using `flock`.

```text
putsync.sh (cron)          get_movie.sh (you)
      │                          │
      ▼                          ▼
 Tries to acquire          Tries to acquire
 /tmp/jellyfin_reel_sort.lock
      │                          │
  ✅ Gets lock               ❌ Lock is busy
  Starts download            Exits cleanly or waits
```

- **If the cron fires while you're already downloading:** It immediately sees the lock is held and logs `"Sync already in progress. Exiting cleanly."` No competing download starts. No bandwidth is wasted.
- **If rclone is already running:** Even before checking the lock, `putsync.sh` checks `pgrep rclone`. If any `rclone` process is active, it exits immediately.
- **The lock file is never deleted:** This prevents a subtle race condition where a departing process could wipe the lock file and allow a new process to steal it mid-download.

---

### ♻️ How Big Downloads Resume Automatically

If your connection drops mid-download, **nothing is lost.** The next time `putsync.sh` runs:

1. `--size-only` compares the byte count of every local file against the remote.
2. Files already fully downloaded (exact size match) are **skipped instantly** — no re-checking, no re-downloading.
3. The file that was interrupted has a smaller size than the remote → rclone **resumes it from the beginning** of that file automatically.
4. All retries are handled internally before giving up on a file: **50 retries** with a **30-second gap** between each, giving cellular and flaky connections plenty of time to recover.

---

### ⏱️ How It Handles Cellular & Flaky Networks

| Problem | Protection |
|:---|:---|
| Modem pauses data flow during band switching | `--timeout 0` — the IO idle timer is fully disabled. rclone waits indefinitely for data to resume. |
| Connection drops entirely | `--retries 50` + `--retries-sleep 30s` — 50 chances to reconnect, each after a 30-second wait. |
| Exponential backoff growing out of control | `--max-backoff 5m` — retry waits are capped at 5 minutes maximum. |
| One bad file blocks the whole queue | `--ignore-errors` — permanently failed files are skipped and the rest of the queue continues. |
| Modem needs time to acquire UW band at start | 5-second warm-up download + 15-second cool-off before sync begins. |

---

### 📋 Watching an Active Download in Real Time

If `putsync.sh` is running from cron in the background, you can follow all active transfer progress live:

```bash
tail -f /var/log/jellyfin-reel-sort.log
```

Every **1 minute**, rclone logs a stats block like this:
```text
Transferred:   12.345 GiB / 45.678 GiB, 27%, 28.4 MiB/s, ETA 20m15s
Transferred:            0 / 1, 0%
Elapsed time:      7m30.0s
Transferring:
 * Show.Name.S04E09.2160p.mkv: 27% /45.68G, 28.4M/s, 20m15s
```

The log is automatically rotated when it reaches **50MB**, keeping the last run in `.log.1`.

---

## ⚙️ Advanced Settings

Want to peek under the hood? You can edit `~/.config/jellyfin-reel-sort.conf` to customize exactly how things work. 

| Setting | What it means | Default |
| :--- | :--- | :--- |
| `DOWNLOADS_DIR` | Where raw downloads land | `~/Jellyfin/downloads/` |
| `MEDIA_DIR` | Where Jellyfin looks for media | `~/Jellyfin/media/` |
| `SYNC_STREAMS` | Number of concurrent HTTP Range streams per file (higher = saturates more bandwidth) | `4` |
| `CLEANUP_MODE` | Should we delete the raw download after linking? (`none`, `delete`, or `move`) | `none` (saves the file for seeding) |
| `DOWNLOAD_SUBTITLES` | Automatically fetch subtitles for your media? | `true` |

---

## 🤝 The Team

Built with ❤️ by movie nerds, for movie nerds.

- **Charles Peters** ([@sircharlesxx](https://github.com/sircharlesxx)) — Creator & Main Developer
- **Kyle Keller** ([@kellerk563](https://github.com/kellerk563)) — Core Contributor (Cleanup Pipeline & Magic Janitor)
