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

- **The Need for Speed (Parallel Multi-Streaming):** Standard downloads pull a file sequentially over a single TCP connection, which often fails to saturate high-bandwidth links due to window sizing limits or carrier-level traffic shaping. To solve this, we utilize **concurrent HTTP Range requests**. By splitting large media files and opening 8 parallel streams simultaneously, we force network load balancers and carriers to allocate maximum available bandwidth, allowing you to easily saturate gigabit fiber or 5G Ultra Wideband links.
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

## 🏃‍♂️ Quick Installation

Ready to get started? Run this on your NAS or Linux server:

```bash
git clone https://github.com/sircharlesxx/jellyfin-reel-sort.git
cd jellyfin-reel-sort
./install.sh
```

Our smart installer will automatically find your media folders, configure your cloud connection, and set everything up for you!

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

## ⚙️ Advanced Settings

Want to peek under the hood? You can edit `~/.config/jellyfin-reel-sort.conf` to customize exactly how things work. 

| Setting | What it means | Default |
| :--- | :--- | :--- |
| `DOWNLOADS_DIR` | Where raw downloads land | `~/Jellyfin/downloads/` |
| `MEDIA_DIR` | Where Jellyfin looks for media | `~/Jellyfin/media/` |
| `SYNC_STREAMS` | Number of concurrent HTTP Range streams per file (higher = saturates more bandwidth) | `8` |
| `CLEANUP_MODE` | Should we delete the raw download after linking? (`none`, `delete`, or `move`) | `none` (saves the file for seeding) |
| `DOWNLOAD_SUBTITLES` | Automatically fetch subtitles for your media? | `true` |

---

## 🤝 The Team

Built with ❤️ by movie nerds, for movie nerds.

- **Charles Peters** ([@sircharlesxx](https://github.com/sircharlesxx)) — Creator & Main Developer
- **Kyle Keller** ([@kellerk563](https://github.com/kellerk563)) — Core Contributor (Cleanup Pipeline & Magic Janitor)
