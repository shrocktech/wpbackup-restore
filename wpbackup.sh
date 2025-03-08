#!/bin/bash

# -----------------------------------------------------------------------------
# WordPress Backup Script with Dynamic S3 Integration
#
# This script backs up WordPress sites by:
# 1. Looping through all WordPress installations in /var/www/ (or configurable directory).
# 2. Extracting database credentials (DB_NAME, DB_USER, DB_PASSWORD) from wp-config.php.
# 3. Dumping the MySQL database for each WordPress site.
# 4. Creating a .tar.gz archive containing:
#    - wp-content directory
#    - wp-config.php file
#    - SQL database dump
#    - A site-specific backup log ([site]_backup.log).
# 5. Uploading the archive to an S3-compatible storage via rclone.
# 6. Applying a retention policy for cleanup.
#
# Requirements:
# - rclone, tar, mysqldump must be installed and accessible.
# - S3-compatible storage must be configured in rclone with remotes named [S3Provider] and [S3Backup].
#
# Usage:
# - Run as root: wpbackup
# - Run with dry-run mode: wpbackup -dryrun
#
# Configuration:
# - Set environment variables to override defaults (e.g., RCLONE_CONF, BASE_DIR, GLOBAL_LOG_FILE).
# - Ensure WordPress sites are in $BASE_DIR (e.g., /var/www/example.com/ with wp-config.php in that directory).
# -----------------------------------------------------------------------------

set -e

# ---------------------------
# Step 1: Check for Required Tools
# ---------------------------
for cmd in rclone mysqldump tar; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: $cmd is not installed. Please install it and try again."
        exit 1
    fi
done

# ---------------------------
# Step 2: Check for -dryrun Flag
# ---------------------------
if [[ "$1" == "-dryrun" ]]; then
    DRYRUN=true
    echo "Dry run mode enabled. No changes will be made."
else
    DRYRUN=false
fi

# ---------------------------
# Step 3: Set Dynamic Variables
# ---------------------------

# Path to rclone configuration file (override with RCLONE_CONF env var)
RCLONE_CONF="${RCLONE_CONF:-/root/.config/rclone/rclone.conf}"
if [ ! -f "$RCLONE_CONF" ]; then
    echo "Error: rclone configuration file not found at $RCLONE_CONF. Please configure rclone and try again."
    exit 1
fi

# Use the generic alias remote from rclone.conf (append : for rclone syntax)
REMOTE_NAME="${REMOTE_NAME:-S3Backup:}"

# Log and construct the remote destination dynamically
echo "Using remote alias '$REMOTE_NAME' defined in rclone.conf."
DAILY_FOLDER="$(date +'%Y%m%d')_Daily_Backup_Job"
FULL_REMOTE_PATH="${REMOTE_NAME}${DAILY_FOLDER}"

# Global log file (override with GLOBAL_LOG_FILE env var)
GLOBAL_LOG_FILE="${GLOBAL_LOG_FILE:-/var/log/wp-content-backup-summary.log}"

# Temporary working directory
TEMP_DIR=$(mktemp -d)

# Base directory for WordPress installations (override with BASE_DIR env var)
BASE_DIR="${BASE_DIR:-/var/www}"

# Set rclone flags for dry run
if [ "$DRYRUN" = true ]; then
    RCLONE_FLAGS="--dry-run"
else
    RCLONE_FLAGS=""
fi

# ---------------------------
# Step 4: Backup Retention Functions
# ---------------------------

# Function to list backup folders
get_backup_folders() {
    rclone lsf "${REMOTE_NAME}" --dirs-only | grep -E '[0-9]{8}_Daily_Backup_Job$' || true
}

# Function to check if a date is a Sunday
is_sunday() {
    local date_str="$1"
    date -d "${date_str:0:4}-${date_str:4:2}-${date_str:6:2}" +%w | grep -q '^0$'
}

# Function to check if a date is the last day of the month
is_last_day_of_month() {
    local date_str="$1"
    local year="${date_str:0:4}"
    local month="${date_str:4:2}"
    local day="${date_str:6:2}"
    local last_day=$(date -d "$year-$month-01 + 1 month - 1 day" +%d)
    [ "$day" = "$last_day" ]
}

# Function to apply retention policy
apply_retention_policy() {
    echo "$(date): Starting backup retention management..." | tee -a "$GLOBAL_LOG_FILE"

    mapfile -t folders < <(get_backup_folders | sort)
    if [ ${#folders[@]} -eq 0 ]; then
        echo "$(date): No backup folders found for retention management." | tee -a "$GLOBAL_LOG_FILE"
        return
    fi

    declare -A keep_folders
    local today=$(date +%Y%m%d)
    local deleted_count=0
    local retained_count=0

    for ((i=${#folders[@]}-1; i>=0; i--)); do
        folder="${folders[i]}"
        date_str="${folder:0:8}"
        age_days=$(( ( $(date -d "$today" +%s) - $(date -d "$date_str" +%s) ) / 86400 ))

        if [ $age_days -lt 7 ]; then
            keep_folders[$folder]="daily"
            continue
        fi

        if [ $age_days -lt 28 ] && is_sunday "$date_str"; then
            keep_folders[$folder]="weekly"
            continue
        fi

        if [ $age_days -lt 90 ] && is_last_day_of_month "$date_str"; then
            keep_folders[$folder]="monthly"
            continue
        fi
    done

    for folder in "${folders[@]}"; do
        if [ -z "${keep_folders[$folder]:-}" ]; then
            echo "$(date): Deleting $folder (doesn't match retention rules)" | tee -a "$GLOBAL_LOG_FILE"
            rclone purge $RCLONE_FLAGS "${REMOTE_NAME}${folder}" 2>>"$GLOBAL_LOG_FILE" || echo "Error deleting $folder" | tee -a "$GLOBAL_LOG_FILE"
            ((deleted_count++))
        else
            echo "$(date): Keeping $folder (${keep_folders[$folder]} backup)" | tee -a "$GLOBAL_LOG_FILE"
            ((retained_count++))
        fi
    done

    echo "$(date): Backup retention complete. Retained: $retained_count, Deleted: $deleted_count" | tee -a "$GLOBAL_LOG_FILE"
}

# ---------------------------
# Step 5: Perform Backups
# ---------------------------

echo "$(date): Backup process started." | tee -a "$GLOBAL_LOG_FILE"

for dir in "$BASE_DIR"/*/ ; do
    WP_CONFIG="${dir}wp-config.php"

    if [ ! -f "$WP_CONFIG" ]; then
        echo "$(date): No wp-config.php found in $dir. Skipping." | tee -a "$GLOBAL_LOG_FILE"
        continue
    fi

    DB_NAME=$(grep -oP "define\s*\(\s*'DB_NAME'\s*,\s*'\K[^']+" "$WP_CONFIG")
    DB_USER=$(grep -oP "define\s*\(\s*'DB_USER'\s*,\s*'\K[^']+" "$WP_CONFIG")
    DB_PASSWORD=$(grep -oP "define\s*\(\s*'DB_PASSWORD'\s*,\s*'\K[^']+" "$WP_CONFIG")

    DOMAIN_NAME=$(basename "$dir")
    SITE_LOG_FILE="/tmp/${DOMAIN_NAME}_backup.log"
    WP_CONTENT_DIR="${dir}wp-content"
    DB_DUMP="/tmp/${DB_NAME}_$(date +'%Y-%m-%d').sql"
    ARCHIVE_NAME="${DOMAIN_NAME}_$(date +'%Y-%m-%d').tar.gz"

    if mysqldump -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" > "$DB_DUMP" 2>>"$SITE_LOG_FILE"; then
        tar -czvf "$ARCHIVE_NAME" -C "$dir" "wp-content" "wp-config.php" -C /tmp "$(basename "$DB_DUMP")" "$(basename "$SITE_LOG_FILE")"
        rclone copy $RCLONE_FLAGS -v "$ARCHIVE_NAME" "$FULL_REMOTE_PATH" --log-file="$SITE_LOG_FILE"
    fi

    rm -v "$ARCHIVE_NAME" "$SITE_LOG_FILE" "$DB_DUMP"
done

apply_retention_policy
echo "$(date): Backup process completed successfully." | tee -a "$GLOBAL_LOG_FILE"