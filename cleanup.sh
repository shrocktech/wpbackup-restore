#!/bin/bash

# WordPress Site Removal Script
# This script removes all files from a deleted WordPress installation

set -e

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root."
    exit 1
fi

# Check for dry run flag
if [[ "$1" == "-dryrun" ]]; then
    DRYRUN=true
    echo "Dry run mode enabled. No changes will be made."
    # Shift parameters so $1 becomes the domain (if provided)
    shift
else
    DRYRUN=false
fi

BASE_DIR="${BASE_DIR:-/var/www}"
LOG_FILE="/var/log/wpsitecleanup.log"

# Initialize log file
if [ "$DRYRUN" = false ]; then
    echo "=== WordPress Site Cleanup Started at $(date) ===" > "$LOG_FILE"
else
    echo "=== WordPress Site Cleanup DRY RUN at $(date) ===" > "$LOG_FILE"
fi

# Prompt for domain name interactively
if [ -z "$1" ]; then
    echo "Enter the domain name to clean up (e.g., example.com):"
    read -p "> " DOMAIN
else
    DOMAIN="$1"
fi

if [ -z "$DOMAIN" ]; then
    echo "No domain specified. Exiting."
    exit 1
fi

SITE_DIR="$BASE_DIR/$DOMAIN"

echo "Starting cleanup for domain: $DOMAIN" | tee -a "$LOG_FILE"
if [ "$DRYRUN" = true ]; then
    echo "[DRY RUN] No files will be deleted" | tee -a "$LOG_FILE"
fi

# Check if site directory exists
if [ -d "$SITE_DIR" ]; then
    echo "Found site directory: $SITE_DIR" | tee -a "$LOG_FILE"
    SPACE_FREED=$(du -sh "$SITE_DIR" | cut -f1)
    
    if [ "$DRYRUN" = false ]; then
        echo "Removing site files..." | tee -a "$LOG_FILE"
        rm -rf "$SITE_DIR"
        echo "✓ Removed site directory, freed approximately $SPACE_FREED" | tee -a "$LOG_FILE"
    else
        echo "[DRY RUN] Would remove site directory ($SPACE_FREED)" | tee -a "$LOG_FILE"
    fi
else
    echo "Site directory not found at $SITE_DIR" | tee -a "$LOG_FILE"
fi

# Look for restore directories
RESTORE_DIRS=$(find "$BASE_DIR" -maxdepth 1 -name "wprestore_*" -type d 2>/dev/null | grep -i "$DOMAIN" || true)

if [ -n "$RESTORE_DIRS" ]; then
    echo "Found restore directories:" | tee -a "$LOG_FILE"
    echo "$RESTORE_DIRS" | tee -a "$LOG_FILE"
    
    for dir in $RESTORE_DIRS; do
        SPACE_FREED=$(du -sh "$dir" | cut -f1)
        if [ "$DRYRUN" = false ]; then
            rm -rf "$dir"
            echo "✓ Removed restore directory: $dir (freed approximately $SPACE_FREED)" | tee -a "$LOG_FILE"
        else
            echo "[DRY RUN] Would remove restore directory: $dir ($SPACE_FREED)" | tee -a "$LOG_FILE"
        fi
    done
fi

# Look for backup files
BACKUP_DIR="${BACKUP_DIR:-/var/backups/wordpress_backups}"
if [ -d "$BACKUP_DIR" ]; then
    BACKUP_FILES=$(find "$BACKUP_DIR" -name "${DOMAIN}*.tar.gz" -type f 2>/dev/null || true)
    
    if [ -n "$BACKUP_FILES" ]; then
        echo "Found backup files:" | tee -a "$LOG_FILE"
        echo "$BACKUP_FILES" | tee -a "$LOG_FILE"
        
        TOTAL_SIZE=$(du -ch $BACKUP_FILES | grep total$ | cut -f1)
        if [ "$DRYRUN" = false ]; then
            rm -f $BACKUP_FILES
            echo "✓ Removed backup files, freed approximately $TOTAL_SIZE" | tee -a "$LOG_FILE"
        else
            echo "[DRY RUN] Would remove backup files ($TOTAL_SIZE)" | tee -a "$LOG_FILE"
        fi
    else
        echo "No backup files found for $DOMAIN" | tee -a "$LOG_FILE"
    fi
fi

echo "----------------------------------------" | tee -a "$LOG_FILE"
if [ "$DRYRUN" = false ]; then
    echo "Cleanup process completed for $DOMAIN at $(date)" | tee -a "$LOG_FILE"
else
    echo "Dry run cleanup simulation completed for $DOMAIN at $(date)" | tee -a "$LOG_FILE"
fi

echo ""
if [ "$DRYRUN" = false ]; then
    echo "Space freed during cleanup has been logged to $LOG_FILE"
else
    echo "This was a dry run. No files were deleted."
    echo "To perform the actual cleanup, run: wpcleanup $DOMAIN"
fi