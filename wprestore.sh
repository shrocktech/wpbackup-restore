#!/bin/bash

# --------------------------------------------------------------------------
# WordPress Restore Script with Backup File Confirmation
#
# This script dynamically retrieves the S3 remote alias and path
# from rclone.conf to work with any S3-compatible provider.
#
# It supports dry runs, dynamic prompts, and logging for restore actions.
# --------------------------------------------------------------------------

# Function to initialize logging
init_logging() {
    if [ ! -z "$LOG_FILE" ] && [ ! -z "$WP_INSTALL_DIR" ]; then
        # Ensure the directory exists
        mkdir -p "$(dirname "$LOG_FILE")"
        # Create or clear the log file
        echo "=== WordPress Restore Script Started at $(date) ===" > "$LOG_FILE"
        return 0
    else
        return 1
    fi
}

# Function to check available disk space based on backup file size
check_disk_space() {
    # Get available space
    local available_space=$(df -BG /tmp | awk 'NR==2 {print $4}' | sed 's/G//')
    
    # Get backup file size
    echo "Checking backup file size..." | tee -a "$LOG_FILE"
    
    if [ "$USE_LOCAL_BACKUP" = true ]; then
        local backup_size_mb=$(du -b "$LOCAL_BACKUP_FILE" | cut -f1)
    else
        local backup_size_mb=$(rclone size "$FULL_REMOTE_PATH/$LATEST_DIR/$LATEST_BACKUP" --json | grep -o '"bytes":[0-9]*' | grep -o '[0-9]*')
    fi
    
    local backup_size_gb=$(echo "scale=2; $backup_size_mb/1024/1024/1024" | bc)
    local overhead_gb=1  # 1GB overhead for extraction and processing
    local required_space=$(echo "scale=0; $backup_size_gb+$overhead_gb+0.5" | bc | cut -d. -f1)
    
    # Ensure minimum required space is at least 2GB
    if [ -z "$required_space" ] || [ "$required_space" -lt 2 ]; then
        required_space=2
        echo "Setting minimum required space to 2GB" | tee -a "$LOG_FILE"
    fi
    
    echo "Backup file size: ${backup_size_gb}GB" | tee -a "$LOG_FILE"
    echo "Required space with overhead: ${required_space}GB" | tee -a "$LOG_FILE"
    
    if [ "$available_space" -lt "$required_space" ]; then
        echo "Error: Insufficient disk space in /tmp directory." | tee -a "$LOG_FILE"
        echo "Available: ${available_space}GB, Required: ${required_space}GB" | tee -a "$LOG_FILE"
        echo "Please free up some space and try again." | tee -a "$LOG_FILE"
        exit 1
    fi
    
    echo "Disk space check passed. Available: ${available_space}GB" | tee -a "$LOG_FILE"
}

# Function to clean up temporary files
cleanup_tmp_files() {
    if [ -d "$TEMP_DIR" ]; then
        echo "Cleaning up temporary files..." | tee -a "$LOG_FILE"
        rm -rf "$TEMP_DIR" 2>/dev/null
        if [ $? -eq 0 ]; then
            echo "✓ Temporary files cleaned up successfully" | tee -a "$LOG_FILE"
            return 0
        else
            echo "Warning: Failed to clean up temporary files at $TEMP_DIR" | tee -a "$LOG_FILE"
            return 1
        fi
    else
        echo "No temporary files found to clean up" | tee -a "$LOG_FILE"
        return 0
    fi
}

# Function to install pv if not present
ensure_pv_installed() {
    if ! command -v pv >/dev/null 2>&1; then
        echo "Installing pv for progress monitoring..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update && apt-get install -y pv
        elif command -v yum >/dev/null 2>&1; then
            yum install -y pv
        else
            echo "Could not install pv. Progress monitoring will be limited."
            return 1
        fi
    fi
    return 0
}

# Function to create database backup with error handling
create_db_backup() {
    local db_name="$1"
    local db_user="$2"
    local db_pass="$3"
    local backup_file="$4"
    
    echo "Creating database backup before restore..." | tee -a "$LOG_FILE"
    
    # First try without tablespace info
    if mysqldump -h localhost -u "$db_user" -p"$db_pass" --no-tablespaces "$db_name" > "$backup_file" 2>/dev/null; then
        echo "Database backup created successfully at: $backup_file" | tee -a "$LOG_FILE"
        return 0
    else
        # If that fails, try with reduced privileges
        echo "Attempting backup with reduced privileges..." | tee -a "$LOG_FILE"
        if mysqldump -h localhost -u "$db_user" -p"$db_pass" --no-tablespaces --skip-triggers --skip-events "$db_name" > "$backup_file" 2>/dev/null; then
            echo "Database backup created with reduced functionality at: $backup_file" | tee -a "$LOG_FILE"
            return 0
        else
            echo "Warning: Could not create full database backup. Proceeding without backup." | tee -a "$LOG_FILE"
            return 1
        fi
    fi
}

# Trap errors and cleanup
trap 'error_exit $?' ERR

error_exit() {
    echo "An error occurred. Error code: $1"
    read -p "Would you like to clean up temporary files? (yes/no): " CLEANUP_ON_ERROR
    if [[ "$CLEANUP_ON_ERROR" == "yes" ]]; then
        cleanup_tmp_files
    else
        echo "Temporary files left at: $TEMP_DIR"
    fi
    exit 1
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
echo "DEBUG: DRYRUN=$DRYRUN, First argument ($1)"  # Debug statement

# Ensure pv is installed for progress monitoring
ensure_pv_installed

# ---------------------------
# Step 2: Configure Backup Sources
# ---------------------------
# Set local backup directory
LOCAL_BACKUP_DIR="${LOCAL_BACKUP_DIR:-/var/backups/wordpress_backups}"

# Configure S3 backup source
DEFAULT_RCLONE_CONF="/root/.config/rclone/rclone.conf"
if [ ! -f "$DEFAULT_RCLONE_CONF" ]; then
    echo "Default rclone configuration not found at $DEFAULT_RCLONE_CONF"
    read -p "Enter alternative rclone.conf path: " RCLONE_CONF
else
    RCLONE_CONF="$DEFAULT_RCLONE_CONF"
fi

REMOTE_NAME="S3Backup"
FULL_REMOTE_PATH="${REMOTE_NAME}:"

# Verify rclone configuration exists
if [ ! -f "$RCLONE_CONF" ]; then
    echo "Error: rclone configuration file not found at $RCLONE_CONF"
    exit 1
fi

# Verify S3 remote exists in configuration
if ! grep -q "\[$REMOTE_NAME\]" "$RCLONE_CONF"; then
    echo "Error: S3 remote '$REMOTE_NAME' not found in rclone configuration"
    exit 1
fi

# Verify S3 connection without logging
echo "Verifying S3 connection and credentials..."
if ! rclone lsd "$FULL_REMOTE_PATH" >/dev/null 2>&1; then
    echo "Error: Unable to connect to S3. Please check your credentials and configuration."
    exit 1
fi

# Only show success messages if verification passed
echo "✓ S3 credentials verified successfully"
echo "✓ Connected to S3 backup folder"
echo "Using remote alias '$REMOTE_NAME' defined in rclone.conf."
echo "----------------------------------------"

# ---------------------------
# Step 3: Prompt for Domain Name and Verify Installation
# ---------------------------
read -p "Enter the domain name to restore (e.g., websitedomain.com): " DOMAIN

# Define default paths
DEFAULT_WP_PATH="/var/www"
echo "Default WordPress path is: $DEFAULT_WP_PATH"
read -p "Use default path? [Y/n]: " USE_DEFAULT_PATH

if [[ "$USE_DEFAULT_PATH" =~ ^[Nn] ]]; then
    read -p "Enter alternative WordPress installation path: " WP_BASE_PATH
else
    WP_BASE_PATH="$DEFAULT_WP_PATH"
fi

# Define paths
WP_INSTALL_DIR="$WP_BASE_PATH/$DOMAIN"
TIMESTAMP=$(date +%m%d%Y)
RESTORE_DIR="$WP_INSTALL_DIR/wprestore_$TIMESTAMP"
LOG_FILE="$RESTORE_DIR/wprestore.log" # Log file for restore actions

# Create .htaccess for restore directory
create_htaccess() {
    local htaccess="$1/.htaccess"
    echo "Order Deny,Allow" > "$htaccess"
    echo "Deny from all" >> "$htaccess"
}

# Create restore directory with protection
if ! mkdir -p "$RESTORE_DIR"; then
    echo "Error: Failed to create restore directory at $RESTORE_DIR"
    exit 1
fi
create_htaccess "$RESTORE_DIR"

# Verify WordPress installation directory exists
if [ ! -d "$WP_INSTALL_DIR" ]; then
    echo "Error: WordPress installation directory not found at $WP_INSTALL_DIR"
    echo "Please verify the domain name and ensure the WordPress installation exists."
    exit 1
else
    echo "✓ Installation directory verified at $WP_INSTALL_DIR"
fi

# Verify it's a WordPress installation
if [ ! -f "$WP_INSTALL_DIR/wp-config.php" ]; then
    echo "Error: No WordPress installation found at $WP_INSTALL_DIR"
    echo "Missing wp-config.php file. Please verify this is a valid WordPress site."
    exit 1
else
    echo "✓ WordPress installation verified (wp-config.php found)"
fi

# Create log directory if it doesn't exist
mkdir -p "$WP_INSTALL_DIR"

# Initialize logging after we have the domain and paths set up
if ! init_logging; then
    echo "Error: Failed to initialize logging."
    exit 1
fi

# Log initial information with improved formatting
echo "=== WordPress Restore Process Initiated ===" | tee -a "$LOG_FILE"
echo "✓ Domain: $DOMAIN" | tee -a "$LOG_FILE"
echo "✓ Install Directory: $WP_INSTALL_DIR" | tee -a "$LOG_FILE"
echo "✓ WordPress Installation: Verified" | tee -a "$LOG_FILE"
echo "✓ S3 Connection: Verified" | tee -a "$LOG_FILE"
echo "----------------------------------------" | tee -a "$LOG_FILE"

# ---------------------------
# Step 4: Choose Backup Source (Local or Remote)
# ---------------------------
echo "Please choose the backup source:"
echo "1) Local backup (from $LOCAL_BACKUP_DIR)"
echo "2) Remote S3 backup"
echo ""
echo "Default: Option 1 will be selected in 15 seconds..."

read -t 15 -p "Enter your choice (1-2): " BACKUP_SOURCE_CHOICE || true

if [ -z "$BACKUP_SOURCE_CHOICE" ]; then
    echo "No input received, defaulting to local backup"
    BACKUP_SOURCE_CHOICE=1
fi

case "$BACKUP_SOURCE_CHOICE" in
    1)
        echo "Using local backup..." | tee -a "$LOG_FILE"
        USE_LOCAL_BACKUP=true
        
        # Check if local backup directory exists
        if [ ! -d "$LOCAL_BACKUP_DIR" ]; then
            echo "Error: Local backup directory not found at $LOCAL_BACKUP_DIR" | tee -a "$LOG_FILE"
            echo "Would you like to switch to remote S3 backup? (yes/no)"
            read -p "Switch to S3 backup? (yes/no): " SWITCH_TO_S3
            
            if [[ "$SWITCH_TO_S3" == "yes" ]]; then
                USE_LOCAL_BACKUP=false
                echo "Switching to remote S3 backup..." | tee -a "$LOG_FILE"
            else
                echo "Exiting as local backup directory does not exist." | tee -a "$LOG_FILE"
                exit 1
            fi
        fi
        
        if [ "$USE_LOCAL_BACKUP" = true ]; then
            # Find the latest local backup for the domain
            echo "Looking for the latest local backup for '$DOMAIN' in $LOCAL_BACKUP_DIR..." | tee -a "$LOG_FILE"
            LOCAL_BACKUP_FILE=$(find "$LOCAL_BACKUP_DIR" -name "${DOMAIN}*.tar.gz" -type f -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)
            
            if [ -z "$LOCAL_BACKUP_FILE" ]; then
                echo "Error: No local backup files found for $DOMAIN in $LOCAL_BACKUP_DIR." | tee -a "$LOG_FILE"
                echo "Would you like to switch to remote S3 backup? (yes/no)"
                read -p "Switch to S3 backup? (yes/no): " SWITCH_TO_S3
                
                if [[ "$SWITCH_TO_S3" == "yes" ]]; then
                    USE_LOCAL_BACKUP=false
                    echo "Switching to remote S3 backup..." | tee -a "$LOG_FILE"
                else
                    echo "Exiting as no local backup file was found." | tee -a "$LOG_FILE"
                    exit 1
                fi
            else
                echo "Found local backup file: $LOCAL_BACKUP_FILE" | tee -a "$LOG_FILE"
                LATEST_BACKUP=$(basename "$LOCAL_BACKUP_FILE")
            fi
        fi
        ;;
    *)
        echo "Using remote S3 backup..." | tee -a "$LOG_FILE"
        USE_LOCAL_BACKUP=false
        ;;
esac

# ---------------------------
# Step 5: Find Backup Files
# ---------------------------
if [ "$USE_LOCAL_BACKUP" = false ]; then
    # Find the latest backup directory in S3 that contains a backup file for the domain
    echo "Looking for the latest backup directory in $FULL_REMOTE_PATH containing a backup for '$DOMAIN'..." | tee -a "$LOG_FILE"
    
    # Debug: Log the full list of directories
    echo "Full list of directories in $FULL_REMOTE_PATH:" | tee -a "$LOG_FILE"
    rclone lsf "$FULL_REMOTE_PATH" --dirs-only --no-check-dest | tee -a "$LOG_FILE"
    
    # Get the list of directories in reverse chronological order
    DIRECTORIES=$(rclone lsf "$FULL_REMOTE_PATH" --dirs-only --no-check-dest | grep -E '^[0-9]{8}_Daily_Backup_Job/' | sort -r)

    # Check if any directories were found
    if [ -z "$DIRECTORIES" ]; then
        echo "Error: No backup directories found in the S3 bucket matching the expected format (YYYYMMDD_Daily_Backup_Job/)." | tee -a "$LOG_FILE"
        exit 1
    fi

    # Iterate through directories to find the first one containing a backup file for the domain
    LATEST_DIR=""
    LATEST_BACKUP=""
    for DIR in $DIRECTORIES; do
        echo "Checking directory: $DIR" | tee -a "$LOG_FILE"
        # Verify the directory exists
        if rclone lsd "$FULL_REMOTE_PATH/$DIR" >/dev/null 2>&1; then
            # Look for a backup file matching the domain
            BACKUP_FILE=$(rclone lsf "$FULL_REMOTE_PATH/$DIR" --include "${DOMAIN}*" | sort -r | head -n 1)
            if [ ! -z "$BACKUP_FILE" ]; then
                LATEST_DIR="$DIR"
                LATEST_BACKUP="$BACKUP_FILE"
                break
            else
                echo "No backup file found for '$DOMAIN' in $DIR" | tee -a "$LOG_FILE"
            fi
        else
            echo "Directory $DIR does not exist or is inaccessible." | tee -a "$LOG_FILE"
        fi
    done

    # Check if a suitable directory and backup file were found
    if [ -z "$LATEST_DIR" ] || [ -z "$LATEST_BACKUP" ]; then
        echo "Error: No backup files found for $DOMAIN in any directory." | tee -a "$LOG_FILE"
        exit 1
    fi

    echo "Latest backup directory found: $LATEST_DIR" | tee -a "$LOG_FILE"
    echo "Latest backup file found: $LATEST_BACKUP" | tee -a "$LOG_FILE"
fi

# ---------------------------
# Step 6: Check Space and Download/Copy the Backup
# ---------------------------
if [ "$DRYRUN" = false ]; then
    check_disk_space
fi
TEMP_DIR=$(mktemp -d)

if [ "$DRYRUN" = false ]; then
    if [ "$USE_LOCAL_BACKUP" = true ]; then
        echo "Copying the local backup file to temporary directory..." | tee -a "$LOG_FILE"
        cp "$LOCAL_BACKUP_FILE" "$TEMP_DIR/"
        echo "✓ Local copy completed" | tee -a "$LOG_FILE"
        ARCHIVE_FILE="$TEMP_DIR/$(basename "$LOCAL_BACKUP_FILE")"
    else
        echo "Downloading the backup file from $FULL_REMOTE_PATH/$LATEST_DIR/$LATEST_BACKUP..." | tee -a "$LOG_FILE"
        if ! rclone copy "$FULL_REMOTE_PATH/$LATEST_DIR/$LATEST_BACKUP" "$TEMP_DIR" --progress >/dev/null 2>&1; then
            echo "Error: Failed to download backup file." | tee -a "$LOG_FILE"
            exit 1
        fi
        echo "✓ Download completed" | tee -a "$LOG_FILE"
        ARCHIVE_FILE="$TEMP_DIR/$LATEST_BACKUP"
    fi
    
    echo "Extracting $ARCHIVE_FILE..." | tee -a "$LOG_FILE"
    if ! tar -xzvf "$ARCHIVE_FILE" -C "$TEMP_DIR"; then
        echo "Error: Failed to extract the backup archive." | tee -a "$LOG_FILE"
        exit 1
    fi
    
    # Debug: List extracted contents
    echo "Extracted contents of $TEMP_DIR:" | tee -a "$LOG_FILE"
    ls -lR "$TEMP_DIR" >> "$LOG_FILE" 2>&1 || echo "Error: Cannot list contents of $TEMP_DIR" | tee -a "$LOG_FILE"

    # Find wp-content directory
    WP_CONTENT_DIR=$(find "$TEMP_DIR" -type d -name "wp-content" -print -quit)
    if [ -z "$WP_CONTENT_DIR" ]; then
        echo "Error: wp-content directory not found in extracted backup." | tee -a "$LOG_FILE"
        exit 1
    fi
    echo "Found wp-content at: $WP_CONTENT_DIR" | tee -a "$LOG_FILE"
    CONTENT_SIZE=$(du -sh "$WP_CONTENT_DIR" | cut -f1)
    echo "✓ wp-content directory found ($CONTENT_SIZE)" | tee -a "$LOG_FILE"

    # Find database file
    DB_BACKUP_FILE=$(find "$TEMP_DIR" -type f -name "*.sql" -print -quit)
    if [ -z "$DB_BACKUP_FILE" ]; then
        echo "Error: Database file (.sql) not found in extracted backup." | tee -a "$LOG_FILE"
        exit 1
    fi
    echo "Found database file at: $DB_BACKUP_FILE" | tee -a "$LOG_FILE"
    DB_SIZE=$(du -sh "$DB_BACKUP_FILE" | cut -f1)
    echo "✓ Database backup found ($DB_SIZE)" | tee -a "$LOG_FILE"
else
    if [ "$USE_LOCAL_BACKUP" = true ]; then
        echo "[Dry Run] Would copy and extract local backup file: $LOCAL_BACKUP_FILE" | tee -a "$LOG_FILE"
    else
        echo "[Dry Run] Would download and extract backup file: $FULL_REMOTE_PATH/$LATEST_DIR/$LATEST_BACKUP" | tee -a "$LOG_FILE"
    fi
fi

# Rest of the restore script follows (Steps 7-12) unchanged
# ---------------------------
# Step 7: Extract Database Credentials from EXISTING Site
# ---------------------------
WP_CONFIG_FILE="$WP_INSTALL_DIR/wp-config.php"
if [ "$DRYRUN" = false ]; then
    if [ ! -f "$WP_CONFIG_FILE" ]; then
        echo "Error: Cannot find wp-config.php in the existing WordPress installation at $WP_INSTALL_DIR" | tee -a "$LOG_FILE"
        exit 1
    fi
    
    echo "Reading database credentials from EXISTING wp-config.php at: $WP_CONFIG_FILE" | tee -a "$LOG_FILE"
    
    # Extract database credentials with improved regex
    DB_NAME=$(grep -oP "define\s*\(\s*['\"]DB_NAME['\"]\s*,\s*['\"]\K[^'\"]+(?=['\"])" "$WP_CONFIG_FILE")
    DB_USER=$(grep -oP "define\s*\(\s*['\"]DB_USER['\"]\s*,\s*['\"]\K[^'\"]+(?=['\"])" "$WP_CONFIG_FILE")
    DB_PASSWORD=$(grep -oP "define\s*\(\s*['\"]DB_PASSWORD['\"]\s*,\s*['\"]\K[^'\"]+(?=['\"])" "$WP_CONFIG_FILE")
    DB_HOST=$(grep -oP "define\s*\(\s*['\"]DB_HOST['\"]\s*,\s*['\"]\K[^'\"]+(?=['\"])" "$WP_CONFIG_FILE")

    if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASSWORD" ]; then
        echo "Error: Failed to extract database credentials from existing wp-config.php." | tee -a "$LOG_FILE"
        exit 1
    fi

    echo "Using database credentials from EXISTING wp-config.php" | tee -a "$LOG_FILE"
    echo "Database Name: $DB_NAME" | tee -a "$LOG_FILE"
    echo "Database User: $DB_USER" | tee -a "$LOG_FILE"
    echo "Database Host: localhost" | tee -a "$LOG_FILE"
    # Show last 5 characters of password for verification
    PASSWORD_LENGTH=${#DB_PASSWORD}
    MASKED_PASS=$(printf '*%.0s' $(seq 1 $((PASSWORD_LENGTH-5))))${DB_PASSWORD: -5}
    echo "Database Password: $MASKED_PASS" | tee -a "$LOG_FILE"
else
    echo "[Dry Run] Would extract database credentials from EXISTING wp-config.php" | tee -a "$LOG_FILE"
fi

# ---------------------------
# Step 8: Restore Database
# ---------------------------
if [ "$DRYRUN" = false ] && [ "$RESTORE_DATABASE" = true ]; then
    echo "Listing contents of backup directory:" | tee -a "$LOG_FILE"
    ls -la "$TEMP_DIR" | tee -a "$LOG_FILE"
    
    # Extract domain prefix (without TLD)
    DOMAIN_PREFIX=${DOMAIN%%.*}
    
    # Try multiple patterns to find database file
    echo "Looking for database file with pattern: ${DOMAIN_PREFIX}_db_*.sql" | tee -a "$LOG_FILE"
    DB_BACKUP_FILE=$(find "$TEMP_DIR" -type f -name "${DOMAIN_PREFIX}_db_*.sql" 2>/dev/null || true)
    
    # If not found, try alternative patterns
    if [ -z "$DB_BACKUP_FILE" ]; then
        echo "Trying alternative naming patterns..." | tee -a "$LOG_FILE"
        DB_BACKUP_FILE=$(find "$TEMP_DIR" -type f \( -name "db_${DOMAIN_PREFIX}*.sql" -o -name "db_${DOMAIN}*.sql" -o -name "*_${DOMAIN_PREFIX}*.sql" -o -name "*.sql" \) | head -n1)
    fi
    
    if [ -z "$DB_BACKUP_FILE" ]; then
        echo "Error: No SQL backup file found in $TEMP_DIR" | tee -a "$LOG_FILE"
        echo "Contents of $TEMP_DIR:" | tee -a "$LOG_FILE"
        find "$TEMP_DIR" -type f | tee -a "$LOG_FILE"
        exit 1
    fi
    
    echo "Found database backup file: $DB_BACKUP_FILE" | tee -a "$LOG_FILE"

    # Find and verify table prefixes
    echo "Analyzing table prefixes..." | tee -a "$LOG_FILE"

    # Get existing prefix from wp-config.php
    EXISTING_PREFIX=$(grep -oP "\\\$table_prefix\s*=\s*['\"]\K[^'\"]+(?=['\"]\s*;)" "$WP_INSTALL_DIR/wp-config.php" | tr -d '\n')

    # Get prefix from backup SQL file - MODIFIED to include the underscore
    BACKUP_PREFIX=$(head -n 500 "$DB_BACKUP_FILE" | grep -oP "CREATE TABLE \`\K[^_]*_?(?=[a-zA-Z0-9_])" | head -n 1 | tr -d '\n')

    # If the backup prefix doesn't end with underscore but the existing one does, add it
    if [[ "$EXISTING_PREFIX" == *_ && "$BACKUP_PREFIX" != *_ ]]; then
        BACKUP_PREFIX="${BACKUP_PREFIX}_"
    fi

    # If the backup prefix ends with underscore but the existing one doesn't, remove it
    if [[ "$EXISTING_PREFIX" != *_ && "$BACKUP_PREFIX" == *_ ]]; then
        BACKUP_PREFIX="${BACKUP_PREFIX%_}"
    fi

    if [ "$EXISTING_PREFIX" != "$BACKUP_PREFIX" ]; then
        echo "╔════════════════════════════════════════════════════════════════╗"
        echo "║               TABLE PREFIX MISMATCH DETECTED                   ║"
        echo "╚════════════════════════════════════════════════════════════════╝"
        echo ""
        echo "Current Setup:"
        printf "  • Existing prefix: %s\n" "$EXISTING_PREFIX"
        echo "        vs"
        printf "  • Backup prefix:   %s\n" "$BACKUP_PREFIX"
        echo ""
        echo "ACTION REQUIRED:"
        echo "────────────────────────────────────────────────────────────────"
        echo "You need to edit the following file:"
        echo "$WP_INSTALL_DIR/wp-config.php"
        echo ""
        printf "Find this line on or around line 70:\n"
        printf "  \$table_prefix = '%s';\n" "$EXISTING_PREFIX"
        echo ""
        printf "Change to:\n"
        printf "  \$table_prefix = '%s';\n" "$BACKUP_PREFIX"
        echo ""
        echo "⚠️  IMPORTANT: Make note of this change for future reference"
        echo "────────────────────────────────────────────────────────────────"
        
        echo "Pausing for 30 seconds to note the required changes..."
        sleep 30
        
        echo "Continuing with restore process..." | tee -a "$LOG_FILE"
    fi

    echo "Checking MySQL connection..." | tee -a "$LOG_FILE"
    if ! MYSQL_PWD="$DB_PASSWORD" mysql -h localhost -u "$DB_USER" -e "USE $DB_NAME" 2>/dev/null; then
        echo "Error: Cannot connect to MySQL database. Please check credentials." | tee -a "$LOG_FILE"
        echo "Debug: Attempting connection with: mysql -h localhost -u $DB_USER (password masked) $DB_NAME" | tee -a "$LOG_FILE"
        exit 1
    fi

    # Check for existing tables and offer to delete them
    EXISTING_TABLES=$(MYSQL_PWD="$DB_PASSWORD" mysql -h localhost -u "$DB_USER" -N -e "SHOW TABLES" "$DB_NAME" 2>/dev/null)
    if [ ! -z "$EXISTING_TABLES" ]; then
        echo "╔════════════════════════════════════════════════════════════════╗"
        echo "║               EXISTING DATABASE TABLES FOUND                   ║"
        echo "╚════════════════════════════════════════════════════════════════╝"
        echo ""
        echo "Would you like to delete all existing tables before restore?"
        echo "WARNING: This action cannot be undone!"
        echo "Default: NO (Safest option)"
        echo ""
        read -t 15 -p "Delete existing tables? (yes/no, defaults to no in 15s): " DELETE_TABLES || true
        
        if [[ "$DELETE_TABLES" == "yes" ]]; then
            echo "Deleting all existing tables..." | tee -a "$LOG_FILE"
            MYSQL_PWD="$DB_PASSWORD" mysql -h localhost -u "$DB_USER" "$DB_NAME" 2>/dev/null << EOF
                SET FOREIGN_KEY_CHECKS=0;
                $(echo "$EXISTING_TABLES" | while read table; do echo "DROP TABLE IF EXISTS \`$table\`;"; done)
                SET FOREIGN_KEY_CHECKS=1;
EOF
            if [ $? -eq 0 ]; then
                echo "✓ All existing tables deleted successfully" | tee -a "$LOG_FILE"
            else
                echo "Error: Failed to delete existing tables" | tee -a "$LOG_FILE"
                exit 1
            fi
        else
            echo "Skipping table deletion, proceeding with restore..." | tee -a "$LOG_FILE"
        fi
    fi

    echo "Restoring database from backup..." | tee -a "$LOG_FILE"
    
    # Count total lines in SQL file for progress indication
    TOTAL_LINES=$(wc -l < "$DB_BACKUP_FILE")
    echo "Processing database backup ($(printf "%'d" $TOTAL_LINES) lines)..." | tee -a "$LOG_FILE"
    
    # Use pv for progress monitoring (should be installed by now)
    if command -v pv >/dev/null 2>&1; then
        echo "Restoring $TOTAL_LINES lines of database now..." | tee -a "$LOG_FILE"
        pv -pterb "$DB_BACKUP_FILE" | MYSQL_PWD="$DB_PASSWORD" mysql -h localhost -u "$DB_USER" "$DB_NAME" 2>/dev/null
    else
        echo "Warning: pv installation failed. Using basic progress indicator..." | tee -a "$LOG_FILE"
        echo "Processing SQL file... (this may take a while)" | tee -a "$LOG_FILE"
        echo "Started at: $(date '+%H:%M:%S')" | tee -a "$LOG_FILE"
        MYSQL_PWD="$DB_PASSWORD" mysql -h localhost -u "$DB_USER" "$DB_NAME" < "$DB_BACKUP_FILE" 2>/dev/null &
        PID=$!
        
        while kill -0 $PID 2>/dev/null; do
            echo -n "."
            sleep 2
        done
        echo ""
        echo "Finished at: $(date '+%H:%M:%S')" | tee -a "$LOG_FILE"
    fi

    # Verify database restore
    if [ $? -eq 0 ]; then
        echo "Database restore completed successfully." | tee -a "$LOG_FILE"
    else
        echo "Error: Database restore failed." | tee -a "$LOG_FILE"
        exit 1
    fi
fi

# ---------------------------
# Step 9: Restore wp-content
# ---------------------------
WP_CONTENT_SRC="$TEMP_DIR/wp-content"

if [ "$DRYRUN" = false ] && [ "$RESTORE_WP_CONTENT" = true ]; then
    if [ -d "$WP_CONTENT_SRC" ]; then
        # Create backup with timestamp
        BACKUP_DATE=$(date +%Y%m%d_%H%M%S)
        BACKUP_DIR="$RESTORE_DIR/wp-content_backup_$BACKUP_DATE"
        
        echo "Creating backup of existing wp-content directory..." | tee -a "$LOG_FILE"
        if [ -d "$WP_INSTALL_DIR/wp-content" ]; then
            echo "Backing up to: $BACKUP_DIR" | tee -a "$LOG_FILE"
            mv "$WP_INSTALL_DIR/wp-content" "$BACKUP_DIR"
            echo "✓ Existing wp-content backed up successfully" | tee -a "$LOG_FILE"
        fi
        
        echo "Restoring wp-content directory..." | tee -a "$LOG_FILE"
        
        # Progress indicator function for rsync
        progress_bar() {
            local pid=$1
            local delay=0.2
            local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
            local width=50
            echo -ne "\n"
            echo -ne "Copying files:  [                                                  ] 0%"
            echo -ne "\033[s"  # Save cursor position
            
            while kill -0 $pid 2>/dev/null; do
                local temp=${spinstr#?}
                for ((i=0; i<$width; i++)); do
                    echo -ne "\033[u"  # Restore cursor position
                    local percent=$(( (i * 100) / width ))
                    printf "Copying files:  ["
                    for ((j=0; j<$width; j++)); do
                        if [ $j -lt $i ]; then
                            echo -ne "="
                        elif [ $j -eq $i ]; then
                            printf "%c" "$spinstr"
                        else
                            echo -ne " "
                        fi
                    done
                    printf "] %d%%" $percent
                    spinstr=${spinstr:1}${spinstr:0:1}
                    sleep 0.1
                done
            done
            echo -ne "\033[u"  # Restore cursor position one last time
            printf "Copying files:  [%${width}s] 100%%\n" | tr " " "="
            echo "✓ Copy completed successfully!"
        }

        # Use rsync with progress tracking
        rsync -a "$WP_CONTENT_SRC/" "$WP_INSTALL_DIR/wp-content/" >/dev/null 2>&1 &
        PID=$!
        progress_bar $PID
        
        if ! wait $PID; then
            echo "Error: Failed to copy wp-content directory." | tee -a "$LOG_FILE"
            exit 1
        fi
        
        echo "✓ wp-content directory restored successfully" | tee -a "$LOG_FILE"
        
        # Detect existing ownership from parent directory or wp-admin
        echo "Detecting WordPress installation ownership..." | tee -a "$LOG_FILE"
        PARENT_OWNER=$(stat -c "%U:%G" "$WP_INSTALL_DIR")
        WP_ADMIN_OWNER=$(stat -c "%U:%G" "$WP_INSTALL_DIR/wp-admin" 2>/dev/null)

        # Use the most specific ownership information available
        if [ ! -z "$WP_ADMIN_OWNER" ]; then
            TARGET_OWNER="$WP_ADMIN_OWNER"
            echo "Using ownership from wp-admin directory: $TARGET_OWNER" | tee -a "$LOG_FILE"
        else
            TARGET_OWNER="$PARENT_OWNER"
            echo "Using ownership from parent directory: $TARGET_OWNER" | tee -a "$LOG_FILE"
        fi

        echo "Setting directory permissions and ownership..." | tee -a "$LOG_FILE"

        # Ensure critical directories exist
        mkdir -p "$WP_INSTALL_DIR/wp-content/upgrade"
        mkdir -p "$WP_INSTALL_DIR/wp-content/uploads"

        # Set ownership to match rest of WordPress
        echo "Setting ownership to match rest of site: $TARGET_OWNER" | tee -a "$LOG_FILE"
        chown -R "$TARGET_OWNER" "$WP_INSTALL_DIR/wp-content"

        # Count total files and directories for progress
        echo "Counting files and directories..."
        total_items=$(find "$WP_INSTALL_DIR/wp-content" -type f -o -type d | wc -l)
        current=0
        
        echo -ne "Setting permissions: [                                                  ] 0%"
        
        # Set base permissions with progress tracking
        find "$WP_INSTALL_DIR/wp-content" \( -type f -o -type d \) | while read item; do
            if [ -d "$item" ]; then
                chmod 755 "$item"
            else
                chmod 644 "$item"
            fi
            
            ((current++))
            percentage=$((current * 100 / total_items))
            filled=$((percentage / 2))
            spaces=$((50 - filled))
            bar=$(printf "%${filled}s" | tr ' ' '=')
            empty=$(printf "%${spaces}s")
            echo -ne "\rSetting permissions: [${bar}${empty}] ${percentage}%"
        done
        echo -e "\n✓ Base permissions set successfully" | tee -a "$LOG_FILE"

        # Make specific directories writable for plugin/theme updates
        echo "Setting special permissions for WordPress functionality..." | tee -a "$LOG_FILE"
        chmod 775 "$WP_INSTALL_DIR/wp-content"
        chmod 775 "$WP_INSTALL_DIR/wp-content/plugins"
        chmod 775 "$WP_INSTALL_DIR/wp-content/themes"
        chmod 775 "$WP_INSTALL_DIR/wp-content/upgrade"
        chmod 775 "$WP_INSTALL_DIR/wp-content/uploads"

        # Add www-data to the owner's group if needed
        if [[ "$TARGET_OWNER" != "www-data:"* ]]; then
            OWNER_GROUP=$(echo "$TARGET_OWNER" | cut -d: -f2)
            echo "Ensuring www-data has access to $OWNER_GROUP group..." | tee -a "$LOG_FILE"
            
            # Check if www-data is already in the group
            if getent group "$OWNER_GROUP" | grep -q "www-data"; then
                echo "✓ www-data already in $OWNER_GROUP group" | tee -a "$LOG_FILE"
            else
                # Try to add www-data to the group
                echo "Adding www-data to $OWNER_GROUP group..." | tee -a "$LOG_FILE"
                if usermod -a -G "$OWNER_GROUP" www-data 2>/dev/null; then
                    echo "✓ Successfully added www-data to $OWNER_GROUP group" | tee -a "$LOG_FILE"
                else
                    echo "Warning: Could not add www-data to $OWNER_GROUP group (requires root)" | tee -a "$LOG_FILE"
                    echo "You may need to run manually: sudo usermod -a -G $OWNER_GROUP www-data" | tee -a "$LOG_FILE"
                fi
            fi
        fi

        # Test if the web server can write to the uploads directory
        echo "Testing WordPress directory permissions..." | tee -a "$LOG_FILE"
        TEST_FILE="$WP_INSTALL_DIR/wp-content/upgrade/permissions_test_$RANDOM"

        # Try to create a test file as www-data
        if sudo -u www-data touch "$TEST_FILE" 2>/dev/null; then
            rm "$TEST_FILE"
            echo "✓ Permission test successful. WordPress should be able to perform updates." | tee -a "$LOG_FILE"
        else
            echo "⚠️ Permission test failed. WordPress might have trouble with updates." | tee -a "$LOG_FILE"
            echo "Manual commands to fix permissions if needed:" | tee -a "$LOG_FILE"
            echo "  sudo chmod 775 $WP_INSTALL_DIR/wp-content/upgrade" | tee -a "$LOG_FILE"
            echo "  sudo chmod 775 $WP_INSTALL_DIR/wp-content/plugins" | tee -a "$LOG_FILE"
            echo "  sudo usermod -a -G $OWNER_GROUP www-data" | tee -a "$LOG_FILE"
            echo "  sudo systemctl restart apache2 # or nginx if using nginx" | tee -a "$LOG_FILE"
        fi
        
        echo "Note: Previous wp-content backed up to:" | tee -a "$LOG_FILE"
        echo "$BACKUP_DIR" | tee -a "$LOG_FILE"
    else
        echo "Error: wp-content folder not found in the backup archive." | tee -a "$LOG_FILE"
        exit 1
    fi
else
    echo "[Dry Run] Would replace wp-content directory in $WP_INSTALL_DIR" | tee -a "$LOG_FILE"
fi

# ---------------------------
# Step 10: Database Optimization
# ---------------------------
if [ "$DRYRUN" = false ] && [ "$RESTORE_DATABASE" = true ]; then
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║                DATABASE OPTIMIZATION OPTIONS                   ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Would you like to repair and optimize the database tables?"
    echo "1) Yes - Repair and optimize tables (recommended)"
    echo "2) No - Skip optimization"
    echo ""
    echo "Default: Option 1 will be selected in 15 seconds..."
    
    read -t 15 -p "Enter your choice (1-2): " OPTIMIZE_CHOICE || true
    
    if [ -z "$OPTIMIZE_CHOICE" ]; then
        echo "No input received, defaulting to database optimization"
        OPTIMIZE_CHOICE=1
    fi
    
    if [[ "$OPTIMIZE_CHOICE" == "1" ]]; then
        echo "Starting database maintenance and optimization..." | tee -a "$LOG_FILE"
        echo "Note: Optimization warnings are normal and non-critical" | tee -a "$LOG_FILE"
        
        # Get list of all tables after restore
        echo "Retrieving table list..." | tee -a "$LOG_FILE"
        TABLES=$(MYSQL_PWD="$DB_PASSWORD" mysql -h localhost -u "$DB_USER" -N -e "SHOW TABLES" "$DB_NAME" 2>/dev/null)
        
        if [ ! -z "$TABLES" ]; then
            echo "Running repair and optimize on all tables..." | tee -a "$LOG_FILE"
            echo "This may take a while depending on database size..." | tee -a "$LOG_FILE"
            
            # Run mysqlcheck with error suppression
            MYSQL_PWD="$DB_PASSWORD" mysqlcheck -h localhost -u "$DB_USER" --auto-repair --optimize "$DB_NAME" 2>/dev/null | tee -a "$LOG_FILE"
            
            echo "Database maintenance completed with standard notifications" | tee -a "$LOG_FILE"
            
            # Try flushing tables, but don't fail if we can't
            echo "Attempting to flush database tables..." | tee -a "$LOG_FILE"
            if MYSQL_PWD="$DB_PASSWORD" mysql -h localhost -u "$DB_USER" "$DB_NAME" -e "FLUSH TABLES" 2>/dev/null; then
                echo "✓ Tables flushed successfully" | tee -a "$LOG_FILE"
            else
                echo "Note: Table flush skipped (requires additional privileges)" | tee -a "$LOG_FILE"
            fi
            
            echo "✓ Database optimization process completed" | tee -a "$LOG_FILE"
        else
            echo "No tables found in database. Skipping optimization." | tee -a "$LOG_FILE"
        fi
    else
        echo "Database optimization skipped by user choice" | tee -a "$LOG_FILE"
    fi
fi

# ---------------------------
# Step 11: Final Verification
# ---------------------------
if [ "$DRYRUN" = false ]; then
    echo "Running final verifications..." | tee -a "$LOG_FILE"
    
    # Table prefix verification section
    if [ "$EXISTING_PREFIX" != "$BACKUP_PREFIX" ]; then
        UPDATED_PREFIX=$(grep -oP "\\\$table_prefix\s*=\s*['\"]\K[^'\"]+(?=['\"]\s*;)" "$WP_INSTALL_DIR/wp-config.php")
        if [ "$UPDATED_PREFIX" != "$BACKUP_PREFIX" ]; then
            echo "╔════════════════════════════════════════════════════════════════╗"
            echo "║                  IMPORTANT CONFIGURATION NOTE                  ║"
            echo "╚════════════════════════════════════════════════════════════════╝"
            echo ""
            echo "⚠️  The website will not work until you update the table prefix!"
            echo ""
            echo "Required Change:"
            printf "  Current prefix:  %-30s\n" "$UPDATED_PREFIX"
            printf "  Required prefix: %-30s\n" "$BACKUP_PREFIX"
            echo ""
            echo "File to edit:"
            printf "  %s\n" "$WP_INSTALL_DIR/wp-config.php"
            echo "  (around line 70)"
            echo ""
            echo "════════════════════════════════════════════════════════════════"
        else
            echo "✓ Table prefix configuration verified" | tee -a "$LOG_FILE"
        fi
    fi
    
    echo "Restore process completed!" | tee -a "$LOG_FILE"
    echo "Please verify the site functionality at: https://$DOMAIN" | tee -a "$LOG_FILE"
fi

# ---------------------------
# Step 12: Cleanup
# ---------------------------
if [ "$DRYRUN" = false ]; then
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║                   RESTORE PROCESS COMPLETE                     ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Please verify the site functionality at: https://$DOMAIN" | tee -a "$LOG_FILE"
    echo ""
    echo "Do you want to clean up temporary files and move the backup archive to the restore folder? (yes/no, default: yes)"
    echo "Press 'n' to cancel. Proceeding automatically in 60 seconds..."
    
    # Set up input with timeout and proper error handling
    read -t 60 -p "Confirm cleanup? [Y/n] " USER_INPUT || true
    
    # If no input or timeout, default to yes
    if [ -z "$USER_INPUT" ]; then
        echo "No input received, defaulting to yes"
        USER_INPUT="yes"
    fi
    
    # Convert to lowercase
    USER_INPUT=$(echo "$USER_INPUT" | tr '[:upper:]' '[:lower:]')
    
    if [[ "$USER_INPUT" == "y" || "$USER_INPUT" == "yes" || -z "$USER_INPUT" ]]; then
        # Move archive to restore directory
        if [ -f "$ARCHIVE_FILE" ]; then
            if mv "$ARCHIVE_FILE" "$RESTORE_DIR/"; then
                echo "✓ Backup archive moved to restore directory" | tee -a "$LOG_FILE"
            else
                echo "Warning: Failed to move backup archive" | tee -a "$LOG_FILE"
            fi
        fi
        
        # Cleanup temporary files
        if cleanup_tmp_files; then
            echo "✓ Temporary files cleaned up successfully" | tee -a "$LOG_FILE"
        else
            echo "Warning: Failed to clean up some temporary files" | tee -a "$LOG_FILE"
            echo "You may need to manually remove: $TEMP_DIR" | tee -a "$LOG_FILE"
        fi
        
        echo ""
        echo "All restore files are located in: $RESTORE_DIR"
        echo "This includes:"
        echo "  • Backup archive (.tar.gz)"
        echo "  • Old wp-content backup"
        echo "  • Restore log file"
        echo ""
        echo "Directory is protected from public access via .htaccess"
        echo "You can safely delete the restore directory after verifying the site works correctly."
        echo "Location: $RESTORE_DIR"
    else
        echo "Cleanup skipped. Temporary files are still at $TEMP_DIR" | tee -a "$LOG_FILE"
    fi
else
    echo "[Dry Run] Would clean up temporary files and move the backup archive." | tee -a "$LOG_FILE"
fi