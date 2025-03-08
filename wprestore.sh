#!/bin/bash

# --------------------------------------------------------------------------
# WordPress Restore Script with Backup File Confirmation
#
# This script dynamically retrieves the S3 remote alias and path
# from rclone.conf to work with any S3-compatible provider.
#
# It supports dry runs, dynamic prompts, and logging for restore actions.
# --------------------------------------------------------------------------
#
# Requirements:
# - rclone, tar, mysqldump, mysql, rsync, pv (installed automatically or manually)
#
# Usage:
# - Dry run mode (test without changes): wprestore -dryrun
# - Full restore: wprestore
#
# Configuration:
# - Override defaults with environment variables (e.g., RCLONE_CONF, WP_BASE_PATH)
# --------------------------------------------------------------------------

set -e

# Check for required tools
for cmd in rclone mysqldump mysql rsync tar pv; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: $cmd is not installed. Please install it and try again."
        exit 1
    fi
done

# Trap errors and cleanup
trap 'error_exit $?' ERR

error_exit() {
    local error_code=$1
    echo "An error occurred. Error code: $error_code" | tee -a "${LOG_FILE:-/var/log/wprestore.log}"
    read -p "Would you like to clean up temporary files? (yes/no): " CLEANUP_ON_ERROR
    if [[ "$CLEANUP_ON_ERROR" == "yes" ]]; then
        cleanup_tmp_files
    else
        echo "Temporary files left at: ${TEMP_DIR:-/tmp}" | tee -a "${LOG_FILE:-/var/log/wprestore.log}"
    fi
    exit 1
}

# Function to initialize logging
init_logging() {
    LOG_FILE="${LOG_FILE:-/var/log/wprestore.log}"
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "=== WordPress Restore Script Started at $(date) ===" > "$LOG_FILE"
    return 0
}

# Function to check available disk space based on backup file size
check_disk_space() {
    local available_space=$(df -BG /tmp | awk 'NR==2 {print $4}' | sed 's/G//')
    local backup_size_mb=$(rclone size "$FULL_REMOTE_PATH/$LATEST_DIR/$LATEST_BACKUP" --json | grep -o '"bytes":[0-9]*' | grep -o '[0-9]*')
    local backup_size_gb=$(echo "scale=2; $backup_size_mb/1024/1024/1024" | bc)
    local overhead_gb=1
    local required_space=$(echo "scale=0; $backup_size_gb+$overhead_gb+0.5" | bc | cut -d. -f1)
    required_space=${required_space:-2}  # Minimum 2GB if calculation fails
    echo "Backup file size: ${backup_size_gb}GB" | tee -a "$LOG_FILE"
    echo "Required space with overhead: ${required_space}GB" | tee -a "$LOG_FILE"
    if [ "$available_space" -lt "$required_space" ]; then
        echo "Error: Insufficient disk space in /tmp. Available: ${available_space}GB, Required: ${required_space}GB" | tee -a "$LOG_FILE"
        exit 1
    fi
    echo "Disk space check passed. Available: ${available_space}GB" | tee -a "$LOG_FILE"
}

# Function to clean up temporary files
cleanup_tmp_files() {
    if [ -d "${TEMP_DIR:-/tmp}" ]; then
        echo "Cleaning up temporary files..." | tee -a "${LOG_FILE:-/var/log/wprestore.log}"
        rm -rf "$TEMP_DIR" 2>/dev/null
        if [ $? -eq 0 ]; then
            echo "✓ Temporary files cleaned up successfully" | tee -a "${LOG_FILE:-/var/log/wprestore.log}"
            return 0
        else
            echo "Warning: Failed to clean up temporary files at $TEMP_DIR" | tee -a "${LOG_FILE:-/var/log/wprestore.log}"
            return 1
        fi
    fi
    return 0
}

# Function to install pv if not present (support multiple package managers)
ensure_pv_installed() {
    if ! command -v pv >/dev/null 2>&1; then
        echo "Installing pv for progress monitoring..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update && apt-get install -y pv
        elif command -v yum >/dev/null 2>&1; then
            yum install -y pv
        else
            echo "Warning: Could not install pv. Progress monitoring will be limited." | tee -a "${LOG_FILE:-/var/log/wprestore.log}"
            return 1
        fi
    fi
    return 0
}

# Function to create database backup with error handling
create_db_backup() {
    local db_name="$1" db_user="$2" db_pass="$3" backup_file="$4"
    echo "Creating database backup before restore..." | tee -a "${LOG_FILE:-/var/log/wprestore.log}"
    if mysqldump -h localhost -u "$db_user" -p"$db_pass" --no-tablespaces "$db_name" > "$backup_file" 2>/dev/null; then
        echo "✓ Database backup created successfully at: $backup_file" | tee -a "${LOG_FILE:-/var/log/wprestore.log}"
    else
        echo "Warning: Could not create full database backup. Proceeding without backup." | tee -a "${LOG_FILE:-/var/log/wprestore.log}"
    fi
}

# ---------------------------
# Step 1: Check for -dryrun Flag
# ---------------------------
if [[ "$1" == "-dryrun" ]]; then
    DRYRUN=true
    echo "Dry run mode enabled. No changes will be made."
else
    DRYRUN=false
fi

ensure_pv_installed

# ---------------------------
# Step 2: Configure S3 Alias
# ---------------------------
RCLONE_CONF="${RCLONE_CONF:-/root/.config/rclone/rclone.conf}"
if [ ! -f "$RCLONE_CONF" ]; then
    echo "Error: rclone configuration file not found at $RCLONE_CONF"
    exit 1
fi
REMOTE_NAME="${REMOTE_NAME:-S3Backup}"
FULL_REMOTE_PATH="${REMOTE_NAME}:"
if ! grep -q "\[$REMOTE_NAME\]" "$RCLONE_CONF"; then
    echo "Error: S3 remote '$REMOTE_NAME' not found in rclone configuration" | tee -a "${LOG_FILE:-/var/log/wprestore.log}"
    exit 1
fi
if ! rclone lsd "$FULL_REMOTE_PATH" >/dev/null 2>&1; then
    echo "Error: Unable to connect to S3. Please check your credentials." | tee -a "${LOG_FILE:-/var/log/wprestore.log}"
    exit 1
fi
echo "✓ S3 credentials verified successfully"
echo "✓ Connected to S3 backup folder"
echo "Using remote alias '$REMOTE_NAME' defined in rclone.conf."

# ---------------------------
# Step 3: Prompt for Domain Name and Verify Installation
# ---------------------------
read -p "Enter the domain name to restore (e.g., websitedomain.com): " DOMAIN
WP_BASE_PATH="${WP_BASE_PATH:-/var/www}"
echo "Default WordPress path is: $WP_BASE_PATH"
read -p "Use default path? [Y/n]: " USE_DEFAULT_PATH
if [[ "$USE_DEFAULT_PATH" =~ ^[Nn] ]]; then
    read -p "Enter alternative WordPress installation path: " WP_BASE_PATH
fi
WP_INSTALL_DIR="$WP_BASE_PATH/$DOMAIN"
TIMESTAMP=$(date +%m%d%Y)
RESTORE_DIR="$WP_INSTALL_DIR/wprestore_$TIMESTAMP"
LOG_FILE="${LOG_FILE:-$RESTORE_DIR/wprestore.log}"
mkdir -p "$RESTORE_DIR"
echo "Order Deny,Allow" > "$RESTORE_DIR/.htaccess"
echo "Deny from all" >> "$RESTORE_DIR/.htaccess"
if [ ! -d "$WP_INSTALL_DIR" ] || [ ! -f "$WP_INSTALL_DIR/wp-config.php" ]; then
    echo "Error: Invalid WordPress installation at $WP_INSTALL_DIR"
    exit 1
fi
init_logging
echo "=== WordPress Restore Process Initiated ===" | tee -a "$LOG_FILE"
echo "✓ Domain: $DOMAIN" | tee -a "$LOG_FILE"
echo "✓ Install Directory: $WP_INSTALL_DIR" | tee -a "$LOG_FILE"
echo "✓ S3 Connection: Verified" | tee -a "$LOG_FILE"

# ---------------------------
# Step 4: Find Latest Backup Directory
# ---------------------------
LATEST_DIR=$(rclone lsf "$FULL_REMOTE_PATH" --dirs-only | sort -r | head -n 1)
if [ -z "$LATEST_DIR" ]; then
    echo "Error: No backup directories found in the S3 bucket." | tee -a "$LOG_FILE"
    exit 1
fi
echo "Latest backup directory found: $LATEST_DIR" | tee -a "$LOG_FILE"

# ---------------------------
# Step 5: Find Backup File for the Domain
# ---------------------------
LATEST_BACKUP=$(rclone lsf "$FULL_REMOTE_PATH/$LATEST_DIR" --files-only | grep -E "^${DOMAIN}_[0-9]{4}-[0-9]{2}-[0-9]{2}\.tar\.gz$" | sort -r | head -n 1)
if [ -z "$LATEST_BACKUP" ]; then
    echo "Error: No backup file found for domain '$DOMAIN' in $LATEST_DIR" | tee -a "$LOG_FILE"
    exit 1
fi
echo "Latest backup file found: $LATEST_BACKUP" | tee -a "$LOG_FILE"
if [ "$DRYRUN" = false ]; then
    echo "Please choose restore type:"
    echo "1) Full restore (wp-content + database)"
    echo "2) Database restore only"
    echo "3) Cancel"
    read -t 15 -p "Enter your choice (1-3, default 1 in 15s): " RESTORE_CHOICE || RESTORE_CHOICE=1
    case $RESTORE_CHOICE in
        1) RESTORE_WP_CONTENT=true; RESTORE_DATABASE=true;;
        2) RESTORE_WP_CONTENT=false; RESTORE_DATABASE=true;;
        3) echo "Restore aborted by user." | tee -a "$LOG_FILE"; exit 0;;
        *) RESTORE_WP_CONTENT=true; RESTORE_DATABASE=true;;
    esac
fi

# ---------------------------
# Step 6: Check Space and Download the Backup
# ---------------------------
TEMP_DIR=$(mktemp -d)
if [ "$DRYRUN" = false ]; then
    check_disk_space
    echo "Downloading $LATEST_BACKUP..."
    rclone copy "$FULL_REMOTE_PATH/$LATEST_DIR/$LATEST_BACKUP" "$TEMP_DIR" --progress | tee -a "$LOG_FILE"
    ARCHIVE_FILE="$TEMP_DIR/$LATEST_BACKUP"
    echo "Extracting $ARCHIVE_FILE..."
    tar -xzf "$ARCHIVE_FILE" -C "$TEMP_DIR" | tee -a "$LOG_FILE"
    if [ ! -d "$TEMP_DIR/wp-content" ] || [ ! -f "$TEMP_DIR/"*_db_*.sql ]; then
        echo "Error: Missing wp-content or database file in backup." | tee -a "$LOG_FILE"
        exit 1
    fi
fi

# ---------------------------
# Step 7: Extract Database Credentials
# ---------------------------
WP_CONFIG_FILE="$WP_INSTALL_DIR/wp-config.php"
if [ "$DRYRUN" = false ]; then
    DB_NAME=$(grep -oP "define\s*\(\s*'DB_NAME'\s*,\s*'\K[^']+" "$WP_CONFIG_FILE")
    DB_USER=$(grep -oP "define\s*\(\s*'DB_USER'\s*,\s*'\K[^']+" "$WP_CONFIG_FILE")
    DB_PASSWORD=$(grep -oP "define\s*\(\s*'DB_PASSWORD'\s*,\s*'\K[^']+" "$WP_CONFIG_FILE")
    DB_HOST=$(grep -oP "define\s*\(\s*'DB_HOST'\s*,\s*'\K[^']+" "$WP_CONFIG_FILE" || echo "localhost")
    if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASSWORD" ]; then
        echo "Error: Failed to extract database credentials." | tee -a "$LOG_FILE"
        exit 1
    fi
    echo "Database credentials extracted: $DB_NAME, $DB_USER, [masked]" | tee -a "$LOG_FILE"
fi

# ---------------------------
# Step 8: Restore Database
# ---------------------------
if [ "$DRYRUN" = false ] && [ "$RESTORE_DATABASE" = true ]; then
    DB_BACKUP_FILE=$(find "$TEMP_DIR" -maxdepth 1 -type f -name "*_db_*.sql" | sort -r | head -n1)
    if [ -z "$DB_BACKUP_FILE" ]; then
        echo "Error: No database backup file found." | tee -a "$LOG_FILE"
        exit 1
    fi
    create_db_backup "$DB_NAME" "$DB_USER" "$DB_PASSWORD" "$RESTORE_DIR/db_backup_$TIMESTAMP.sql"
    EXISTING_PREFIX=$(grep -oP "\\\$table_prefix\s*=\s*['\"]\K[^'\"]+(?=['\"])" "$WP_CONFIG_FILE")
    BACKUP_PREFIX=$(head -n 100 "$DB_BACKUP_FILE" | grep -oP "CREATE TABLE \`\K[^_]+(?=_)" | head -n 1)
    if [ "$EXISTING_PREFIX" != "$BACKUP_PREFIX" ]; then
        echo "Table prefix mismatch detected. Please update \$table_prefix in $WP_CONFIG_FILE to $BACKUP_PREFIX" | tee -a "$LOG_FILE"
    fi
    if MYSQL_PWD="$DB_PASSWORD" mysql -h "$DB_HOST" -u "$DB_USER" -e "USE $DB_NAME" 2>/dev/null; then
        EXISTING_TABLES=$(MYSQL_PWD="$DB_PASSWORD" mysql -h "$DB_HOST" -u "$DB_USER" -N -e "SHOW TABLES" "$DB_NAME")
        if [ -n "$EXISTING_TABLES" ]; then
            read -t 15 -p "Delete existing tables? (yes/no, default no in 15s): " DELETE_TABLES || DELETE_TABLES=no
            if [ "$DELETE_TABLES" == "yes" ]; then
                MYSQL_PWD="$DB_PASSWORD" mysql -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -e "SET FOREIGN_KEY_CHECKS=0; DROP TABLE IF EXISTS $EXISTING_TABLES; SET FOREIGN_KEY_CHECKS=1;"
            fi
        fi
        if command -v pv >/dev/null; then
            pv "$DB_BACKUP_FILE" | MYSQL_PWD="$DB_PASSWORD" mysql -h "$DB_HOST" -u "$DB_USER" "$DB_NAME"
        else
            MYSQL_PWD="$DB_PASSWORD" mysql -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" < "$DB_BACKUP_FILE"
        fi
        echo "✓ Database restored successfully" | tee -a "$LOG_FILE"
    else
        echo "Error: MySQL connection failed." | tee -a "$LOG_FILE"
        exit 1
    fi
fi

# ---------------------------
# Step 9: Restore wp-content
# ---------------------------
if [ "$DRYRUN" = false ] && [ "$RESTORE_WP_CONTENT" = true ]; then
    if [ -d "$TEMP_DIR/wp-content" ]; then
        BACKUP_DIR="$RESTORE_DIR/wp-content_backup_$TIMESTAMP"
        if [ -d "$WP_INSTALL_DIR/wp-content" ]; then
            mv "$WP_INSTALL_DIR/wp-content" "$BACKUP_DIR"
            echo "✓ Existing wp-content backed up to $BACKUP_DIR" | tee -a "$LOG_FILE"
        fi
        rsync -a "$TEMP_DIR/wp-content/" "$WP_INSTALL_DIR/wp-content/" --progress | tee -a "$LOG_FILE"
        TARGET_OWNER=$(stat -c "%U:%G" "$WP_INSTALL_DIR" || stat -c "%U:%G" "$WP_INSTALL_DIR/wp-admin")
        chown -R "$TARGET_OWNER" "$WP_INSTALL_DIR/wp-content"
        find "$WP_INSTALL_DIR/wp-content" -type d -exec chmod 755 {} \; -o -type f -exec chmod 644 {} \;
        chmod 775 "$WP_INSTALL_DIR/wp-content" "$WP_INSTALL_DIR/wp-content/plugins" "$WP_INSTALL_DIR/wp-content/themes" "$WP_INSTALL_DIR/wp-content/upgrade" "$WP_INSTALL_DIR/wp-content/uploads"
        echo "✓ wp-content restored and permissions set" | tee -a "$LOG_FILE"
    else
        echo "Error: wp-content not found in backup." | tee -a "$LOG_FILE"
        exit 1
    fi
fi

# ---------------------------
# Step 10: Database Optimization
# ---------------------------
if [ "$DRYRUN" = false ] && [ "$RESTORE_DATABASE" = true ]; then
    read -t 15 -p "Optimize database? (1=yes, 2=no, default 1 in 15s): " OPTIMIZE_CHOICE || OPTIMIZE_CHOICE=1
    if [ "$OPTIMIZE_CHOICE" == "1" ]; then
        TABLES=$(MYSQL_PWD="$DB_PASSWORD" mysql -h "$DB_HOST" -u "$DB_USER" -N -e "SHOW TABLES" "$DB_NAME")
        if [ -n "$TABLES" ]; then
            MYSQL_PWD="$DB_PASSWORD" mysqlcheck -h "$DB_HOST" -u "$DB_USER" --auto-repair --optimize "$DB_NAME" | tee -a "$LOG_FILE"
            echo "✓ Database optimized" | tee -a "$LOG_FILE"
        fi
    fi
fi

# ---------------------------
# Step 11: Final Verification and Cleanup
# ---------------------------
if [ "$DRYRUN" = false ]; then
    if [ "$EXISTING_PREFIX" != "$BACKUP_PREFIX" ] && [ "$(grep -oP "\\\$table_prefix\s*=\s*['\"]\K[^'\"]+(?=['\"])" "$WP_CONFIG_FILE")" != "$BACKUP_PREFIX" ]; then
        echo "⚠️ Table prefix mismatch unresolved. Update $WP_CONFIG_FILE with $BACKUP_PREFIX" | tee -a "$LOG_FILE"
    fi
    echo "Restore completed! Verify at https://$DOMAIN" | tee -a "$LOG_FILE"
    read -t 60 -p "Clean up temporary files? (Y/n, default yes in 60s): " CLEANUP || CLEANUP=yes
    if [[ "$CLEANUP" =~ ^[Yy]|^$ ]]; then
        mv "$ARCHIVE_FILE" "$RESTORE_DIR/" 2>/dev/null && echo "✓ Backup archive moved" | tee -a "$LOG_FILE"
        cleanup_tmp_files
        echo "Restore files in $RESTORE_DIR" | tee -a "$LOG_FILE"
    fi
fi

echo "Script execution completed."