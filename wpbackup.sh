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

GLOBAL_LOG_FILE="${GLOBAL_LOG_FILE:-/var/log/wp-content-backup-summary.log}"
TEMP_DIR=$(mktemp -d)
BASE_DIR="${BASE_DIR:-/var/www}"

if [ "$DRYRUN" = true ]; then
    RCLONE_FLAGS="--dry-run"
else
    RCLONE_FLAGS=""
fi

# Function to list backup folders
get_backup_folders() {
    echo "$(date): Listing backup folders in ${REMOTE_NAME}..." | tee -a "$GLOBAL_LOG_FILE"
    folders=$(rclone lsf "${REMOTE_NAME}" --dirs-only)
    echo "$(date): All folders found: $folders" | tee -a "$GLOBAL_LOG_FILE"
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
    echo "$(date): Starting backup retention management..." | tee -a "$GLOBAL_LOG_FILE"

    mapfile -t folders < <(get_backup_folders | sort)
    if [ ${#folders[@]} -eq 0 ]; then
        echo "$(date): No backup folders found for retention management." | tee -a "$GLOBAL_LOG_FILE"
        return
    fi

    echo "$(date): Found these backup folders:" | tee -a "$GLOBAL_LOG_FILE"
    for folder in "${folders[@]}"; do
        echo "  - $folder" | tee -a "$GLOBAL_LOG_FILE"
    done

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
            # Add trailing slash to ensure targeting the directory
            rclone purge $RCLONE_FLAGS "${REMOTE_NAME}${folder}/" 2>>"$GLOBAL_LOG_FILE" || echo "Error deleting $folder" | tee -a "$GLOBAL_LOG_FILE"
            ((deleted_count++))
        else
            echo "$(date): Keeping $folder (${keep_folders[$folder]} backup)" | tee -a "$GLOBAL_LOG_FILE"
            ((retained_count++))
        fi
    done

    echo "$(date): Backup retention complete. Retained: $retained_count, Deleted: $deleted_count" | tee -a "$GLOBAL_LOG_FILE"
}

# Perform backups
echo "$(date): Backup process started." | tee -a "$GLOBAL_LOG_FILE"

# Loop through WordPress installations
for dir in "$BASE_DIR"/*/ ; do
    if [ -f "${dir}wp-config.php" ]; then
        WP_CONFIG="${dir}wp-config.php"

        DB_NAME=$(grep -oP "define\s*\(\s*'DB_NAME'\s*,\s*'\K[^']+" "$WP_CONFIG")
        DB_USER=$(grep -oP "define\s*\(\s*'DB_USER'\s*,\s*'\K[^']+" "$WP_CONFIG")
        DB_PASSWORD=$(grep -oP "define\s*\(\s*'DB_PASSWORD'\s*,\s*'\K[^']+" "$WP_CONFIG")

        DOMAIN_NAME=$(basename "$dir")
        SITE_LOG_FILE="/tmp/${DOMAIN_NAME}_backup.log"
        WP_CONTENT_DIR="${dir}wp-content"
        
        # Use domain-prefixed database backup filename format
        DOMAIN_PREFIX=${DOMAIN_NAME%%.*}
        DB_DUMP="/tmp/${DOMAIN_PREFIX}_db_$(date +'%Y-%m-%d').sql"
        ARCHIVE_NAME="${DOMAIN_NAME}_$(date +'%Y-%m-%d').tar.gz"

        if mysqldump -u "$DB_USER" -p"$DB_PASSWORD" --no-tablespaces "$DB_NAME" > "$DB_DUMP" 2>>"$SITE_LOG_FILE"; then
            tar -czvf "$ARCHIVE_NAME" -C "$dir" "wp-content" "wp-config.php" -C /tmp "$(basename "$DB_DUMP")" "$(basename "$SITE_LOG_FILE")"
            rclone copy $RCLONE_FLAGS -v "$ARCHIVE_NAME" "$FULL_REMOTE_PATH" --log-file="$SITE_LOG_FILE"

            # Verify the upload (skip verification in dry run)
            if [ "$DRYRUN" = false ]; then
                if rclone ls "${FULL_REMOTE_PATH}/$(basename "$ARCHIVE_NAME")" > /dev/null 2>&1; then
                    echo "$(date): Successfully uploaded $ARCHIVE_NAME to $FULL_REMOTE_PATH." | tee -a "$GLOBAL_LOG_FILE"
                else
                    echo "$(date): Error: Failed to verify upload of $ARCHIVE_NAME to $FULL_REMOTE_PATH." | tee -a "$GLOBAL_LOG_FILE"
                fi
            fi
        fi

        rm -v "$ARCHIVE_NAME" "$SITE_LOG_FILE" "$DB_DUMP"
    fi
done

apply_retention_policy
echo "$(date): Backup process completed successfully." | tee -a "$GLOBAL_LOG_FILE"