#!/bin/bash

# WordPress Backup Script with S3 Integration (hardened)
# - Backs up WP sites: wp-content + wp-config.php + DB dump
# - Uploads to S3 via rclone
# - Optional local copy of today's backups
# - Retention policy on S3 folders
#
# Usage:
#   wpbackup
#   wpbackup -dryrun
#   wpbackup example.com
#   wpbackup -dryrun example.com
#
# Config env vars (optional):
#   BASE_DIR=/var/www
#   LOCAL_BACKUP_DIR=/var/backups/wordpress_backups
#   STAGING_ROOT=/var/backups/wpbackup_staging
#   RCLONE_CONF=/root/.config/rclone/rclone.conf
#   REMOTE_NAME=S3Backup:
#
# NOTE:
#   This script intentionally avoids /tmp for large files to prevent filling the root disk.

set -Eeuo pipefail

# ---------- Required tools ----------
for cmd in rclone mysqldump tar grep sed date find mktemp du basename; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: $cmd is not installed. Please install it and try again."
    exit 1
  fi
done

# ---------- Args ----------
DRYRUN=false
SPECIFIC_SITE=""

for arg in "$@"; do
  if [[ "$arg" == "-dryrun" ]]; then
    DRYRUN=true
    echo "Dry run mode enabled. No changes will be made."
  elif [[ "$arg" != -* ]]; then
    SPECIFIC_SITE="$arg"
    echo "Processing only site: $SPECIFIC_SITE"
  fi
done

# ---------- Config ----------
RCLONE_CONF="${RCLONE_CONF:-/root/.config/rclone/rclone.conf}"
if [ ! -f "$RCLONE_CONF" ]; then
  echo "Error: rclone configuration file not found at $RCLONE_CONF."
  exit 1
fi
export RCLONE_CONFIG="$RCLONE_CONF"

REMOTE_NAME="${REMOTE_NAME:-S3Backup:}"
echo "Using remote alias '$REMOTE_NAME' defined in rclone.conf."

DAILY_FOLDER="$(date +'%Y%m%d')_Daily_Backup_Job"
FULL_REMOTE_PATH="${REMOTE_NAME}${DAILY_FOLDER}"

BASE_DIR="${BASE_DIR:-/var/www}"
LOCAL_BACKUP_DIR="${LOCAL_BACKUP_DIR:-/var/backups/wordpress_backups}"
STAGING_ROOT="${STAGING_ROOT:-/var/backups/wpbackup_staging}"

mkdir -p "$LOCAL_BACKUP_DIR"
mkdir -p "$STAGING_ROOT"

if [ "$DRYRUN" = true ]; then
  RCLONE_FLAGS="--dry-run"
else
  RCLONE_FLAGS=""
fi

RUN_ID="$(date +'%Y%m%d_%H%M%S')_$$"
RUN_STAGING_DIR="$(mktemp -d -p "$STAGING_ROOT" "wpbackup_${RUN_ID}_XXXX")"

cleanup() {
  # Always remove our staging directory
  if [ -n "${RUN_STAGING_DIR:-}" ] && [[ "$RUN_STAGING_DIR" == "$STAGING_ROOT"/wpbackup_* ]]; then
    rm -rf "$RUN_STAGING_DIR" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# ---------- Helpers ----------
log() {
  echo "[$(date +'%F %T')] $*"
}

# Function to list backup folders on remote
get_backup_folders() {
  # list only directories at remote root
  local folders
  folders="$(rclone lsf "${REMOTE_NAME}" --dirs-only 2>/dev/null || true)"
  echo "$folders" | sed 's:/*$::' | grep -E '^[0-9]{8}_Daily_Backup_Job$' || true
}

is_sunday() {
  local date_str="$1"
  date -d "${date_str:0:4}-${date_str:4:2}-${date_str:6:2}" +%w | grep -q '^0$'
}

is_last_day_of_month() {
  local date_str="$1"
  local year="${date_str:0:4}"
  local month="${date_str:4:2}"
  local day="${date_str:6:2}"
  local last_day
  last_day="$(date -d "$year-$month-01 + 1 month - 1 day" +%d)"
  [ "$day" = "$last_day" ]
}

apply_retention_policy() {
  log "Starting backup retention management..."

  mapfile -t folders < <(get_backup_folders | sort)
  if [ ${#folders[@]} -eq 0 ]; then
    log "No backup folders found for retention management."
    return 0
  fi

  declare -A keep_folders
  local today
  today="$(date +%Y%m%d)"
  local deleted_count=0
  local retained_count=0

  for ((i=${#folders[@]}-1; i>=0; i--)); do
    local folder="${folders[i]}"
    local date_str="${folder:0:8}"
    local age_days
    age_days=$(( ( $(date -d "$today" +%s) - $(date -d "$date_str" +%s) ) / 86400 ))

    if [ "$age_days" -lt 7 ]; then
      keep_folders["$folder"]="daily"
      continue
    fi

    if [ "$age_days" -lt 28 ] && is_sunday "$date_str"; then
      keep_folders["$folder"]="weekly"
      continue
    fi

    if [ "$age_days" -lt 90 ] && is_last_day_of_month "$date_str"; then
      keep_folders["$folder"]="monthly"
      continue
    fi
  done

  for folder in "${folders[@]}"; do
    if [ -z "${keep_folders[$folder]:-}" ]; then
      log "Deleting $folder (doesn't match retention rules)"
      rclone purge $RCLONE_FLAGS "${REMOTE_NAME}${folder}/" >/dev/null 2>&1 || log "WARN: Error deleting $folder"
      ((deleted_count++)) || true
    else
      log "Keeping $folder (${keep_folders[$folder]} backup)"
      ((retained_count++)) || true
    fi
  done

  log "Backup retention complete. Retained: $retained_count, Deleted: $deleted_count"
}

# Extract DB credentials from wp-config.php
extract_wp_db_creds() {
  local wp_config="$1"

  local db_name db_user db_pass
  db_name="$(grep -oP "define\s*\(\s*'DB_NAME'\s*,\s*'\K[^']+" "$wp_config" 2>/dev/null || true)"
  db_user="$(grep -oP "define\s*\(\s*'DB_USER'\s*,\s*'\K[^']+" "$wp_config" 2>/dev/null || true)"
  db_pass="$(grep -oP "define\s*\(\s*'DB_PASSWORD'\s*,\s*'\K[^']+" "$wp_config" 2>/dev/null || true)"

  if [ -z "$db_name" ] || [ -z "$db_user" ]; then
    return 1
  fi

  echo "$db_name|$db_user|$db_pass"
}

# Backup one site
backup_site() {
  local dir="$1"
  local wp_config="${dir%/}/wp-config.php"
  local domain_name
  domain_name="$(basename "$dir")"

  local site_stage_dir
  site_stage_dir="$(mktemp -d -p "$RUN_STAGING_DIR" "site_${domain_name}_XXXX")"

  local site_log_file="${site_stage_dir}/${domain_name}_backup.log"
  local mysql_warn_file="${site_stage_dir}/mysql_warnings.tmp"
  local rclone_out_file="${site_stage_dir}/rclone_output.tmp"

  # fresh log
  {
    echo "WordPress Backup Log for $domain_name - $(date)"
    echo "----------------------------------------------"
  } > "$site_log_file"

  log "Processing site: $domain_name"

  if [ ! -f "$wp_config" ]; then
    echo "ERROR: wp-config.php not found at $wp_config" | tee -a "$site_log_file"
    return 0
  fi

  local creds
  if ! creds="$(extract_wp_db_creds "$wp_config")"; then
    echo "ERROR: Could not parse DB creds from $wp_config" | tee -a "$site_log_file"
    return 0
  fi

  local db_name db_user db_pass
  db_name="${creds%%|*}"
  db_user="$(echo "$creds" | cut -d'|' -f2)"
  db_pass="$(echo "$creds" | cut -d'|' -f3)"

  echo "Found database: $db_name" >> "$site_log_file"

  local wp_content_dir="${dir%/}/wp-content"
  if [ ! -d "$wp_content_dir" ]; then
    echo "ERROR: wp-content directory not found at $wp_content_dir" | tee -a "$site_log_file"
    return 0
  fi

  local domain_prefix="${domain_name%%.*}"
  local db_dump="${site_stage_dir}/${domain_prefix}_db_$(date +'%Y-%m-%d').sql"
  local archive_path="${site_stage_dir}/${domain_name}_$(date +'%Y-%m-%d').tar.gz"

  echo "Creating database dump..." >> "$site_log_file"
  if ! mysqldump -u "$db_user" -p"$db_pass" --no-tablespaces "$db_name" > "$db_dump" 2>"$mysql_warn_file"; then
    echo "✗ Database dump failed for $domain_name" | tee -a "$site_log_file"
    return 0
  fi

  echo "✓ Database dump successful ($(du -h "$db_dump" | cut -f1) size)" | tee -a "$site_log_file"

  echo "Creating backup archive..." >> "$site_log_file"
  
  # Create archive from site files + DB dump + site log
  # We stage db_dump + log in site_stage_dir, so we can pack everything reliably in one tar call.
  # Note: tar exit code 1 means "file changed as we read it" - archive is still valid
  set +e
  tar -czf "$archive_path" \
      -C "$dir" "wp-content" "wp-config.php" \
      -C "$site_stage_dir" "$(basename "$db_dump")" "$(basename "$site_log_file")" 2>&1
  tar_exit=$?
  set -e

  # Exit code 1 = "file changed as we read it" - archive is still valid
  if [ $tar_exit -gt 1 ]; then
    echo "✗ Archive creation failed for $domain_name (tar exit code: $tar_exit)" | tee -a "$site_log_file"
    return 0
  elif [ $tar_exit -eq 1 ]; then
    echo "⚠ Archive created with warnings for $domain_name (files changed during backup)" | tee -a "$site_log_file"
  fi

  # Verify archive was actually created
  if [ ! -f "$archive_path" ] || [ ! -s "$archive_path" ]; then
    echo "✗ Archive creation failed for $domain_name (file missing or empty)" | tee -a "$site_log_file"
    return 0
  fi

  echo "✓ Archive created: $(basename "$archive_path") ($(du -h "$archive_path" | cut -f1) size)" | tee -a "$site_log_file"
  echo "Uploading to S3..." >> "$site_log_file"

  if ! rclone copy $RCLONE_FLAGS "$archive_path" "$FULL_REMOTE_PATH" --progress >"$rclone_out_file" 2>&1; then
    echo "✗ rclone upload failed for $domain_name (see $rclone_out_file)" | tee -a "$site_log_file"
    return 0
  fi

  # Verify upload (skip in dry-run)
  if [ "$DRYRUN" = false ]; then
    if rclone ls "${FULL_REMOTE_PATH}/$(basename "$archive_path")" >/dev/null 2>&1; then
      echo "✓ Successfully uploaded to S3" | tee -a "$site_log_file"

      echo "✓ Keeping local copy in $LOCAL_BACKUP_DIR" | tee -a "$site_log_file"
      cp -f "$archive_path" "$LOCAL_BACKUP_DIR/" || echo "WARN: Could not copy local backup" | tee -a "$site_log_file"
    else
      echo "✗ Failed to verify upload to S3" | tee -a "$site_log_file"
      return 0
    fi
  fi

  echo "Backup process for $domain_name completed at $(date)" >> "$site_log_file"
  log "Completed processing $domain_name"
  return 0
}

# ---------- Main ----------
log "Backup process started"

# Local retention: keep only today's local backups (same behavior you had)
if [ "$DRYRUN" = false ]; then
  log "Cleaning up old local backups..."
  todays_date="$(date +'%Y-%m-%d')"
  find "$LOCAL_BACKUP_DIR" -type f -name "*.tar.gz" 2>/dev/null | while read -r file; do
    if [[ "$(basename "$file")" != *"_${todays_date}.tar.gz" ]]; then
      log "Deleting old backup: $(basename "$file")"
      rm -f "$file" || true
    else
      log "Keeping today's backup: $(basename "$file")"
    fi
  done
  log "Local cleanup complete."

  # Extra safety: if anything ever drops tarballs into /root, remove ones older than today
  find /root -maxdepth 1 -name "*.tar.gz" -type f -mtime +0 -delete 2>/dev/null || true
fi

# Run backup(s)
if [ -n "$SPECIFIC_SITE" ]; then
  SITE_DIR=""
  for dir in "$BASE_DIR"/*/; do
    if [ "$(basename "$dir")" = "$SPECIFIC_SITE" ] && [ -f "${dir%/}/wp-config.php" ]; then
      SITE_DIR="$dir"
      break
    fi
  done

  if [ -n "$SITE_DIR" ]; then
    backup_site "$SITE_DIR"
  else
    echo "Error: WordPress site $SPECIFIC_SITE not found in $BASE_DIR or wp-config.php missing."
    exit 1
  fi
else
  for dir in "$BASE_DIR"/*/; do
    if [ -f "${dir%/}/wp-config.php" ]; then
      backup_site "$dir"
    fi
  done
fi

# Retention policy on S3 folders only for full run
if [ -z "$SPECIFIC_SITE" ]; then
  apply_retention_policy
fi

log "Backup process completed successfully"
