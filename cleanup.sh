#!/bin/bash

# WordPress Site Removal Script
# This script removes all files from a deleted WordPress installation
# Usage: wpremove domain.com

set -e

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root."
    exit 1
fi

# Check if domain was provided
if [ -z "$1" ]; then
    echo "Error: Please provide the domain name to clean up."
    echo "Usage: wpremove domain.com"
    exit 1
fi

DOMAIN="$1"
BASE_DIR="${BASE_DIR:-/var/www}"
SITE_DIR="$BASE_DIR/$DOMAIN"
LOG_FILE="/var/log/wpsitecleanup.log"

# Initialize log file
echo "=== WordPress Site Cleanup for $DOMAIN Started at $(date) ===" | tee -a "$LOG_FILE"

# Check if site directory exists
if [ -d "$SITE_DIR" ]; then
    echo "Found site directory: $SITE_DIR" | tee -a "$LOG_FILE"
    echo "Removing site files..." | tee -a "$LOG_FILE"
    
    # Calculate disk space to be freed
    SPACE_FREED=$(du -sh "$SITE_DIR" | cut -f1)
    
    rm -rf "$SITE_DIR"
    echo "✓ Removed site directory, freed approximately $SPACE_FREED" | tee -a "$LOG_FILE"
else
    echo "Site directory not found at $SITE_DIR" | tee -a "$LOG_FILE"
fi

# Look for restore directories
RESTORE_DIRS=$(find "$BASE_DIR" -maxdepth 1 -name "wprestore_*_$DOMAIN" -o -name "$DOMAIN*_wprestore_*" -o -name "wprestore_*" -type d 2>/dev/null | grep -i "$DOMAIN" || true)

if [ -n "$RESTORE_DIRS" ]; then
    echo "Found restore directories:" | tee -a "$LOG_FILE"
    echo "$RESTORE_DIRS" | tee -a "$LOG_FILE"
    
    for dir in $RESTORE_DIRS; do
        SPACE_FREED=$(du -sh "$dir" | cut -f1)
        rm -rf "$dir"
        echo "✓ Removed restore directory: $dir (freed approximately $SPACE_FREED)" | tee -a "$LOG_FILE"
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
        rm -f $BACKUP_FILES
        echo "✓ Removed backup files, freed approximately $TOTAL_SIZE" | tee -a "$LOG_FILE"
    else
        echo "No backup files found for $DOMAIN" | tee -a "$LOG_FILE"
    fi
fi

echo "----------------------------------------" | tee -a "$LOG_FILE"
echo "Cleanup process completed for $DOMAIN at $(date)" | tee -a "$LOG_FILE"
echo ""
echo "To remove any associated databases, use the following commands:"
echo "  mysql -e \"SHOW DATABASES LIKE '${DOMAIN%%.*}_%';\"  # To find matching databases"
echo "  mysql -e \"DROP DATABASE database_name;\"  # To remove a specific database"

# Show total space freed
echo ""
echo "Space freed during cleanup process is logged in $LOG_FILE"