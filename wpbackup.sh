#!/bin/bash

# WordPress Backup Script with S3 Integration
# Backs up WP sites with database dumps and wp-content, uploads to S3.
# Usage: wpbackup or wpbackup -dryrun
# Configuration: Override BASE_DIR, RCLONE_CONF, or GLOBAL_LOG_FILE env vars if needed.

set -e

# Check for required tools
for cmd in rclone mysqldump tar; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: $cmd is not installed. Please install it and try again."
        exit 1
    fi
done

# Check for dry run flag
if [[ "$1" == "-dryrun" ]]; then
    DRYRUN=true
    echo "Dry run mode enabled. No changes will be made."
else
    DRYRUN=false
fi

# Set dynamic variables
RCLONE_CONF="${RCLONE_CONF:-/root/.config/rclone/rclone.conf}"
if [ ! -f "$RCLONE_CONF" ]; then
    echo "Error: rclone configuration file not found at $RCLONE_CONF."
    exit 1
fi

REMOTE_NAME="${REMOTE_NAME:-S3Backup:}"
echo "Using remote alias '$REMOTE_NAME' defined in rclone.conf."
DAILY_FOLDER="$(date +'%Y%m%d')_Daily_Backup_Job"
FULL_REMOTE_PATH="${REMOTE_NAME}${DAILY_FOLDER}"

TEMP_DIR=$(mktemp -d)
BASE_DIR="${BASE_DIR:-/var/www}"
LOCAL_BACKUP_DIR="${LOCAL_BACKUP_DIR:-/var/backups/wordpress_backups}"

if [ "$DRYRUN" = true ]; then
    RCLONE_FLAGS="--dry-run"
else
    RCLONE_FLAGS=""
fi

# Function to list backup folders
get_backup_folders() {
    folders=$(rclone lsf "${REMOTE_NAME}" --dirs-only)
    echo "$folders" | grep -E '[0-9]{8}_Daily_Backup_Job$' || true
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
    echo "Starting backup retention management..."

    mapfile -t folders < <(get_backup_folders | sort)
    if [ ${#folders[@]} -eq 0 ]; then
        echo "No backup folders found for retention management."
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
            echo "Deleting $folder (doesn't match retention rules)"
            # Add trailing slash to ensure targeting the directory
            rclone purge $RCLONE_FLAGS "${REMOTE_NAME}${folder}/" 2>/dev/null || echo "Error deleting $folder"
            ((deleted_count++))
        else
            echo "Keeping $folder (${keep_folders[$folder]} backup)"
            ((retained_count++))
        fi
    done

    echo "Backup retention complete. Retained: $retained_count, Deleted: $deleted_count"
}

# Perform backups
echo "Backup process started at $(date)"

# Create local backup directory if it doesn't exist
mkdir -p "$LOCAL_BACKUP_DIR"

# Remove previous day's backups from local backup directory
if [ "$DRYRUN" = false ]; then
    echo "Cleaning up old local backups..."
    find "$LOCAL_BACKUP_DIR" -name "*.tar.gz" -type f -mtime +1 -delete
fi

# Loop through WordPress installations
for dir in "$BASE_DIR"/*/ ; do
    if [ -f "${dir}wp-config.php" ]; then
        WP_CONFIG="${dir}wp-config.php"
        DOMAIN_NAME=$(basename "$dir")
        SITE_LOG_FILE="/tmp/${DOMAIN_NAME}_backup.log"
        
        # Create a fresh log file with header for this site
        echo "WordPress Backup Log for $DOMAIN_NAME - $(date)" > "$SITE_LOG_FILE"
        echo "----------------------------------------------" >> "$SITE_LOG_FILE"
        
        echo "Processing site: $DOMAIN_NAME" | tee -a "$SITE_LOG_FILE"
        
        # Extract database credentials
        DB_NAME=$(grep -oP "define\s*\(\s*'DB_NAME'\s*,\s*'\K[^']+" "$WP_CONFIG")
        DB_USER=$(grep -oP "define\s*\(\s*'DB_USER'\s*,\s*'\K[^']+" "$WP_CONFIG")
        DB_PASSWORD=$(grep -oP "define\s*\(\s*'DB_PASSWORD'\s*,\s*'\K[^']+" "$WP_CONFIG")
        
        echo "Found database: $DB_NAME" >> "$SITE_LOG_FILE"
        
        WP_CONTENT_DIR="${dir}wp-content"
        # Check wp-content exists
        if [ ! -d "$WP_CONTENT_DIR" ]; then
            echo "ERROR: wp-content directory not found at $WP_CONTENT_DIR" | tee -a "$SITE_LOG_FILE"
            continue
        fi
        
        # Use domain-prefixed database backup filename format
        DOMAIN_PREFIX=${DOMAIN_NAME%%.*}
        DB_DUMP="/tmp/${DOMAIN_PREFIX}_db_$(date +'%Y-%m-%d').sql"
        ARCHIVE_NAME="${DOMAIN_NAME}_$(date +'%Y-%m-%d').tar.gz"
        
        echo "Creating database dump..." >> "$SITE_LOG_FILE"
        # Redirect MySQL warnings to a separate file to keep our log clean
        mysqldump -u "$DB_USER" -p"$DB_PASSWORD" --no-tablespaces "$DB_NAME" > "$DB_DUMP" 2>/tmp/mysql_warnings.tmp
        
        if [ $? -eq 0 ]; then
            echo "✓ Database dump successful ($(du -h "$DB_DUMP" | cut -f1) size)" | tee -a "$SITE_LOG_FILE"
            
            echo "Creating backup archive..." >> "$SITE_LOG_FILE"
            tar -czf "$ARCHIVE_NAME" -C "$dir" "wp-content" "wp-config.php" -C /tmp "$(basename "$DB_DUMP")" "$(basename "$SITE_LOG_FILE")"
            
            echo "✓ Archive created: $ARCHIVE_NAME ($(du -h "$ARCHIVE_NAME" | cut -f1) size)" | tee -a "$SITE_LOG_FILE"
            echo "Uploading to S3..." >> "$SITE_LOG_FILE"
            
            # Redirect rclone output to a file instead of the site log
            rclone copy $RCLONE_FLAGS "$ARCHIVE_NAME" "$FULL_REMOTE_PATH" --progress >/tmp/rclone_output.tmp 2>&1
            
            # Verify the upload (skip verification in dry run)
            if [ "$DRYRUN" = false ]; then
                if rclone ls "${FULL_REMOTE_PATH}/$(basename "$ARCHIVE_NAME")" > /dev/null 2>&1; then
                    echo "✓ Successfully uploaded to S3" | tee -a "$SITE_LOG_FILE"
                    
                    # Keep a local copy of today's backup
                    echo "✓ Keeping local copy in $LOCAL_BACKUP_DIR" | tee -a "$SITE_LOG_FILE"
                    cp "$ARCHIVE_NAME" "$LOCAL_BACKUP_DIR/"
                else
                    echo "✗ Failed to verify upload to S3" | tee -a "$SITE_LOG_FILE"
                fi
            fi
            
            echo "Backup process for $DOMAIN_NAME completed at $(date)" >> "$SITE_LOG_FILE"
            
            # Clean up the original archive after copying it to local backup dir
            rm -f "$ARCHIVE_NAME" "$DB_DUMP" /tmp/mysql_warnings.tmp /tmp/rclone_output.tmp
        else
            echo "✗ Database dump failed for $DOMAIN_NAME" | tee -a "$SITE_LOG_FILE"
        fi
        
        echo "Completed processing $DOMAIN_NAME"
    fi
done

# Clean up temp directory
rm -rf "$TEMP_DIR"

apply_retention_policy
echo "Backup process completed successfully at $(date)"