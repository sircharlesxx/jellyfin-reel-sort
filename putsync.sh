#!/bin/bash

# --- Configuration ---
REMOTE_NAME="put.io"
# CHANGED: Dedicated drop zone for rclone, separate from the Jellyfin library
LOCAL_PATH="/home/mariofishy/Jellyfin/downloads/" 
LOG_FILE="/var/log/rclone_putio_copy.log"

# Define the path for our lock file. /tmp is a good location.
LOCK_FILE="/tmp/rclone_putio.lock"

# prevent script from running more than one times
# in case the previous run didnt finish yet
(
  flock -n 200 || exit 1

  # --- The Sync Command ---
  # This part will only run if the lock was successfully acquired.

  echo "--- Starting put.io copy job at $(date) ---" >> "$LOG_FILE"

  /usr/bin/rclone copy "$REMOTE_NAME:/" "$LOCAL_PATH" \
    --progress \
    --log-file="$LOG_FILE"
    
  echo "--- Copy job finished at $(date) ---" >> "$LOG_FILE"
  echo "" >> "$LOG_FILE"

# ... (your existing rclone copy command) ...
  
  echo "--- Starting blind sort and hardlink at $(date) ---" >> "$LOG_FILE"
  
  # RUN THE SORTER 
  python3 /home/mariofishy/Jellyfin/sorter.py >> "$LOG_FILE" 2>&1
  
  echo "--- Copy and Sort jobs finished at $(date) ---" >> "$LOG_FILE"
  echo "" >> "$LOG_FILE"

) 200>"$LOCK_FILE"
