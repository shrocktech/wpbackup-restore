#!/bin/bash

# WordPress Cache Cleanup Script
# This script removes object-cache.php files from all WordPress installations
# Usage: wpcleanup [domain] or wpcleanup -all

set -e

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root."
    exit 1
fi

# Default path for WordPress installations
BASE_DIR="${BASE_DIR:-/var/www}"
LOG_FILE="/var/log/wpcleanup.log"

# Initialize log file
echo "=== WordPress Cache Cleanup Started at $(date) ===" > "$LOG_FILE"

# Function to clean a specific domain
cleanup_domain() {
    local domain="$1"
    local wp_dir="$BASE_DIR/$domain"
    
    echo "Processing site: $domain" | tee -a "$LOG_FILE"
    
    # Verify WordPress installation
    if [ ! -f "$wp_dir/wp-config.php" ]; then
        echo "Error: No WordPress installation found at $wp_dir" | tee -a "$LOG_FILE"
        return 1
    fi
    
    # Check for object-cache.php
    OBJECT_CACHE_FILE="$wp_dir/wp-content/object-cache.php"
    if [ -f "$OBJECT_CACHE_FILE" ]; then
        echo "Found object-cache.php file, removing it to prevent potential issues..." | tee -a "$LOG_FILE"
        if rm "$OBJECT_CACHE_FILE"; then
            echo "✓ object-cache.php removed successfully for $domain" | tee -a "$LOG_FILE"
            return 0
        else
            echo "Warning: Failed to remove object-cache.php file for $domain" | tee -a "$LOG_FILE"
            return 1
        fi
    else
        echo "No object-cache.php file found for $domain" | tee -a "$LOG_FILE"
        return 0
    fi
}

# Main script logic
if [ "$1" == "-all" ]; then
    echo "Cleaning all WordPress installations in $BASE_DIR..." | tee -a "$LOG_FILE"
    
    # Counter variables
    total_sites=0
    cleaned_sites=0
    
    # Process all WordPress installations
    for dir in "$BASE_DIR"/*/ ; do
        if [ -f "${dir}wp-config.php" ]; then
            domain=$(basename "$dir")
            ((total_sites++))
            
            if cleanup_domain "$domain"; then
                ((cleaned_sites++))
            fi
        fi
    done
    
    echo "----------------------------------------" | tee -a "$LOG_FILE"
    echo "Cleanup process completed" | tee -a "$LOG_FILE"
    echo "Total WordPress sites found: $total_sites" | tee -a "$LOG_FILE"
    echo "Sites processed successfully: $cleaned_sites" | tee -a "$LOG_FILE"
    
elif [ -n "$1" ]; then
    # Clean specific domain
    cleanup_domain "$1"
else
    echo "Usage: wpcleanup [domain] or wpcleanup -all" | tee -a "$LOG_FILE"
    echo ""
    echo "Options:"
    echo "  [domain]    Clean object-cache.php for a specific domain"
    echo "  -all        Clean object-cache.php for all WordPress installations"
    echo ""
    echo "Example:"
    echo "  wpcleanup example.com    # Clean only example.com"
    echo "  wpcleanup -all           # Clean all WordPress sites"
fi

echo "Cleanup process completed at $(date)" | tee -a "$LOG_FILE"