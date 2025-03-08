#!/bin/bash

# Function to initialize logging
init_logging() {
    if [ ! -z "$LOG_FILE" ] && [ ! -z "$WP_INSTALL_DIR" ]; then
        mkdir -p "$(dirname "$LOG_FILE")"
        echo "=== WordPress Restore Script Started at $(date) ===" > "$LOG_FILE"
        return 0
    else
        return 1
    fi
}

# Function to check available disk space based on backup file size
check_disk_space() {
    local available_space=$(df -BG /tmp | awk 'NR==2 {print $4}' | sed 's/G//')
    echo "Checking backup file size..." | tee -a "$LOG_FILE"
    local backup_size_mb=$(rclone size "$FULL_REMOTE_PATH/$LATEST_DIR/$LATEST_BACKUP" --json | grep -o '"bytes":[0-9]*' | grep -o '[0-9]*')
    local backup_size_gb=$(echo "scale=2; $backup_size_mb/1024/1024/1024" | bc)
    local overhead_gb=1
    local required_space=$(echo "scale=0; $backup_size_gb+$overhead_gb+0.5" | bc | cut -d. -f1)
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
    if mysqldump -h localhost -u "$db_user" -p"$db_pass" --no-tablespaces "$db_name" > "$backup_file" 2>/dev/null; then
        echo "Database backup created successfully at: $backup_file" | tee -a "$LOG_FILE"
        return 0
    else
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

# Step 1: Check for -dryrun Flag
if [[ "$1" == "-dryrun" ]]; then
    DRYRUN=true
    echo "Dry run mode enabled. No changes will be made."
else
    DRYRUN=false
fi

# Ensure pv is installed for progress monitoring
ensure_pv_installed

# Step 2: Configure S3 Alias
DEFAULT_RCLONE_CONF="/root/.config/rclone/rclone.conf"
RCLONE_CONF="${RCLONE_CONF:-$DEFAULT_RCLONE_CONF}"
if [ ! -f "$RCLONE_CONF" ]; then
    echo "Error: rclone configuration file not found at $RCLONE_CONF"
    exit 1
fi
REMOTE_NAME="S3Backup"
FULL_REMOTE_PATH="${REMOTE_NAME}:"

# Verify S3 connection
echo "Verifying S3 connection and credentials..."
if ! rclone lsd "$FULL_REMOTE_PATH" >/dev/null 2>&1; then
    echo "Error: Unable to connect to S3. Please check your credentials and configuration."
    exit 1
fi
echo "✓ S3 credentials verified successfully"
echo "✓ Connected to S3 backup folder"
echo "Using remote alias '$REMOTE_NAME' defined in rclone.conf."

# Step 3: Prompt for Domain Name and Verify Installation
read -p "Enter the domain name to restore (e.g., websitedomain.com): " DOMAIN
DEFAULT_WP_PATH="/var/www"
echo "Default WordPress path is: $DEFAULT_WP_PATH"
read -p "Use default path? [Y/n]: " USE_DEFAULT_PATH
WP_BASE_PATH="${USE_DEFAULT_PATH,,}" =~ ^[Nn] ? $(read -p "Enter alternative WordPress installation path: ") : "$DEFAULT_WP_PATH"
WP_INSTALL_DIR="$WP_BASE_PATH/$DOMAIN"
TIMESTAMP=$(date +%m%d%Y)
RESTORE_DIR="$WP_INSTALL_DIR/wprestore_$TIMESTAMP"
LOG_FILE="$RESTORE_DIR/wprestore.log"

create_htaccess() {
    local htaccess="$1/.htaccess"
    echo "Order Deny,Allow" > "$htaccess"
    echo "Deny from all" >> "$htaccess"
}

if ! mkdir -p "$RESTORE_DIR"; then
    echo "Error: Failed to create restore directory at $RESTORE_DIR"
    exit 1
fi
create_htaccess "$RESTORE_DIR"

if [ ! -d "$WP_INSTALL_DIR" ]; then
    echo "Error: WordPress installation directory not found at $WP_INSTALL_DIR"
    exit 1
fi
if [ ! -f "$WP_INSTALL_DIR/wp-config.php" ]; then
    echo "Error: No WordPress installation found at $WP_INSTALL_DIR"
    exit 1
fi

if ! init_logging; then
    echo "Error: Failed to initialize logging."
    exit 1
fi

echo "=== WordPress Restore Process Initiated ===" | tee -a "$LOG_FILE"
echo "✓ Domain: $DOMAIN" | tee -a "$LOG_FILE"
echo "✓ Install Directory: $WP_INSTALL_DIR" | tee -a "$LOG_FILE"
echo "✓ WordPress Installation: Verified" | tee -a "$LOG_FILE"
echo "✓ S3 Connection: Verified" | tee -a "$LOG_FILE"

# Step 4: Find Latest Backup Directory
LATEST_DIR=$(rclone lsf "$FULL_REMOTE_PATH" --dirs-only | sort -r | head -n 1)
if [ -z "$LATEST_DIR" ]; then
    echo "Error: No backup directories found in the S3 bucket." | tee -a "$LOG_FILE"
    exit 1
fi
echo "Latest backup directory found: $LATEST_DIR" | tee -a "$LOG_FILE"

# Step 5: Find Backup File for the Domain
LATEST_BACKUP=$(rclone lsf "$FULL_REMOTE_PATH/$LATEST_DIR" --files-only | grep -E "^${DOMAIN}_[0-9]{4}-[0-9]{2}-[0-9]{2}\.tar\.gz$" | sort -r | head -n 1)
if [ -z "$LATEST_BACKUP" ]; then
    echo "Error: No backup file found for domain '$DOMAIN' in the latest directory '$LATEST_DIR'." | tee -a "$LOG_FILE"
    exit 1
fi
echo "Latest backup file found: $LATEST_BACKUP" | tee -a "$LOG_FILE"

# Step 6: Check Space and Download the Backup
if [ "$DRYRUN" = false ]; then
    check_disk_space
fi
TEMP_DIR=$(mktemp -d)

if [ "$DRYRUN" = false ]; then
    echo "Downloading the backup file from $FULL_REMOTE_PATH/$LATEST_DIR/$LATEST_BACKUP..." | tee -a "$LOG_FILE"
    if ! rclone copy "$FULL_REMOTE_PATH/$LATEST_DIR/$LATEST_BACKUP" "$TEMP_DIR" --progress >/dev/null 2>&1; then
        echo "Error: Failed to download backup file." | tee -a "$LOG_FILE"
        exit 1
    fi
    echo "✓ Download completed" | tee -a "$LOG_FILE"
    
    ARCHIVE_FILE="$TEMP_DIR/$LATEST_BACKUP"
    echo "Extracting $ARCHIVE_FILE..."
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

    # Find database file
    DB_BACKUP_FILE=$(find "$TEMP_DIR" -type f -name "*.sql" -print -quit)
    if [ -z "$DB_BACKUP_FILE" ]; then
        echo "Error: Database file (.sql) not found in extracted backup." | tee -a "$LOG_FILE"
        exit 1
    fi
    echo "Found database file at: $DB_BACKUP_FILE" | tee -a "$LOG_FILE"
else
    echo "[Dry Run] Would download and extract backup file: $FULL_REMOTE_PATH/$LATEST_DIR/$LATEST_BACKUP" | tee -a "$LOG_FILE"
fi

# Step 7: Extract Database Credentials
WP_CONFIG_FILE="$WP_INSTALL_DIR/wp-config.php"
if [ "$DRYRUN" = false ]; then
    if [ ! -f "$WP_CONFIG_FILE" ]; then
        echo "Error: Cannot find wp-config.php in the existing WordPress installation." | tee -a "$LOG_FILE"
        exit 1
    fi
    DB_NAME=$(grep -oP "define\s*\(\s*['\"]DB_NAME['\"]\s*,\s*['\"]\K[^'\"]+(?=['\"])" "$WP_CONFIG_FILE")
    DB_USER=$(grep -oP "define\s*\(\s*['\"]DB_USER['\"]\s*,\s*['\"]\K[^'\"]+(?=['\"])" "$WP_CONFIG_FILE")
    DB_PASSWORD=$(grep -oP "define\s*\(\s*['\"]DB_PASSWORD['\"]\s*,\s*['\"]\K[^'\"]+(?=['\"])" "$WP_CONFIG_FILE")
    DB_HOST=$(grep -oP "define\s*\(\s*['\"]DB_HOST['\"]\s*,\s*['\"]\K[^'\"]+(?=['\"])" "$WP_CONFIG_FILE")
    if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASSWORD" ]; then
        echo "Error: Failed to extract database credentials." | tee -a "$LOG_FILE"
        exit 1
    fi
    echo "Using database credentials from existing wp-config.php" | tee -a "$LOG_FILE"
    echo "Database Name: $DB_NAME" | tee -a "$LOG_FILE"
    echo "Database User: $DB_USER" | tee -a "$LOG_FILE"
    echo "Database Host: localhost" | tee -a "$LOG_FILE"
    PASSWORD_LENGTH=${#DB_PASSWORD}
    MASKED_PASS=$(printf '*%.0s' $(seq 1 $((PASSWORD_LENGTH-5))))${DB_PASSWORD: -5}
    echo "Database Password: $MASKED_PASS" | tee -a "$LOG_FILE"
else
    echo "[Dry Run] Would extract database credentials from existing wp-config.php" | tee -a "$LOG_FILE"
fi

# Step 8: Restore Database
if [ "$DRYRUN" = false ]; then
    ls -la "$TEMP_DIR" | tee -a "$LOG_FILE"
    DB_BACKUP_FILE=$(find "$TEMP_DIR" -maxdepth 1 -type f -name "*.sql" | sort -r | head -n1)
    if [ -z "$DB_BACKUP_FILE" ]; then
        echo "Error: No SQL backup file found" | tee -a "$LOG_FILE"
        exit 1
    fi
    echo "Found database backup file: $DB_BACKUP_FILE" | tee -a "$LOG_FILE"

    EXISTING_PREFIX=$(grep -oP "\\\$table_prefix\s*=\s*['\"]\K[^'\"]+(?=['\"]\s*;)" "$WP_INSTALL_DIR/wp-config.php")
    BACKUP_PREFIX=$(head -n 100 "$DB_BACKUP_FILE" | grep -oP "CREATE TABLE \`\K[^_]+(?=_)" | head -n 1)
    if [ "$EXISTING_PREFIX" != "$BACKUP_PREFIX" ]; then
        echo "╔════════════════════════════════════════════════════════════════╗"
        echo "║               TABLE PREFIX MISMATCH DETECTED                   ║"
        echo "╚════════════════════════════════════════════════════════════════╝"
        echo "Current Setup:"
        printf "  • Existing prefix: %s\n" "$EXISTING_PREFIX"
        printf "  • Backup prefix:   %s\n" "$BACKUP_PREFIX"
        echo "ACTION REQUIRED:"
        echo "You need to edit $WP_INSTALL_DIR/wp-config.php"
        printf "Change \$table_prefix = '%s' to \$table_prefix = '%s' (around line 70)\n" "$EXISTING_PREFIX" "$BACKUP_PREFIX"
        echo "⚠️  IMPORTANT: Make note of this change for future reference"
        sleep 30
    fi

    if ! MYSQL_PWD="$DB_PASSWORD" mysql -h localhost -u "$DB_USER" -e "USE $DB_NAME" 2>/dev/null; then
        echo "Error: Cannot connect to MySQL database." | tee -a "$LOG_FILE"
        exit 1
    fi

    EXISTING_TABLES=$(MYSQL_PWD="$DB_PASSWORD" mysql -h localhost -u "$DB_USER" -N -e "SHOW TABLES" "$DB_NAME" 2>/dev/null)
    if [ ! -z "$EXISTING_TABLES" ]; then
        read -t 15 -p "Delete existing tables? (yes/no, defaults to no in 15s): " DELETE_TABLES || true
        if [[ "$DELETE_TABLES" == "yes" ]]; then
            echo "Deleting all existing tables..." | tee -a "$LOG_FILE"
            MYSQL_PWD="$DB_PASSWORD" mysql -h localhost -u "$DB_USER" "$DB_NAME" << EOF
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
    TOTAL_LINES=$(wc -l < "$DB_BACKUP_FILE")
    if command -v pv >/dev/null 2>&1; then
        pv -pterb "$DB_BACKUP_FILE" | MYSQL_PWD="$DB_PASSWORD" mysql -h localhost -u "$DB_USER" "$DB_NAME" 2>/dev/null
    else
        echo "Processing SQL file..." | tee -a "$LOG_FILE"
        MYSQL_PWD="$DB_PASSWORD" mysql -h localhost -u "$DB_USER" "$DB_NAME" < "$DB_BACKUP_FILE" 2>/dev/null
    fi
    if [ $? -eq 0 ]; then
        echo "Database restore completed successfully." | tee -a "$LOG_FILE"
    else
        echo "Error: Database restore failed." | tee -a "$LOG_FILE"
        exit 1
    fi
fi

# Step 9: Restore wp-content
WP_CONTENT_SRC=$(find "$TEMP_DIR" -type d -name "wp-content" -print -quit)
if [ "$DRYRUN" = false ] && [ -n "$WP_CONTENT_SRC" ]; then
    BACKUP_DATE=$(date +%Y%m%d_%H%M%S)
    BACKUP_DIR="$RESTORE_DIR/wp-content_backup_$BACKUP_DATE"
    if [ -d "$WP_INSTALL_DIR/wp-content" ]; then
        echo "Creating backup of existing wp-content directory..." | tee -a "$LOG_FILE"
        mv "$WP_INSTALL_DIR/wp-content" "$BACKUP_DIR"
        echo "✓ Existing wp-content backed up successfully" | tee -a "$LOG_FILE"
    fi
    echo "Restoring wp-content directory..." | tee -a "$LOG_FILE"
    rsync -a "$WP_CONTENT_SRC/" "$WP_INSTALL_DIR/wp-content/" >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo "✓ wp-content directory restored successfully" | tee -a "$LOG_FILE"
        PARENT_OWNER=$(stat -c "%U:%G" "$WP_INSTALL_DIR")
        WP_ADMIN_OWNER=$(stat -c "%U:%G" "$WP_INSTALL_DIR/wp-admin" 2>/dev/null)
        TARGET_OWNER="${WP_ADMIN_OWNER:-$PARENT_OWNER}"
        echo "Setting ownership to match rest of site: $TARGET_OWNER" | tee -a "$LOG_FILE"
        chown -R "$TARGET_OWNER" "$WP_INSTALL_DIR/wp-content"
        chmod -R 755 "$WP_INSTALL_DIR/wp-content"
        echo "✓ Permissions and ownership set" | tee -a "$LOG_FILE"
    else
        echo "Error: Failed to copy wp-content directory." | tee -a "$LOG_FILE"
        exit 1
    fi
    echo "Note: Previous wp-content backed up to: $BACKUP_DIR" | tee -a "$LOG_FILE"
else
    echo "[Dry Run] Would replace wp-content directory in $WP_INSTALL_DIR" | tee -a "$LOG_FILE"
fi

# Step 10: Database Optimization
if [ "$DRYRUN" = false ]; then
    read -t 15 -p "Optimize database tables? (1=Yes, 2=No, default 1 in 15s): " OPTIMIZE_CHOICE || true
    OPTIMIZE_CHOICE=${OPTIMIZE_CHOICE:-1}
    if [ "$OPTIMIZE_CHOICE" -eq 1 ]; then
        echo "Starting database maintenance and optimization..." | tee -a "$LOG_FILE"
        TABLES=$(MYSQL_PWD="$DB_PASSWORD" mysql -h localhost -u "$DB_USER" -N -e "SHOW TABLES" "$DB_NAME" 2>/dev/null)
        if [ ! -z "$TABLES" ]; then
            MYSQL_PWD="$DB_PASSWORD" mysqlcheck -h localhost -u "$DB_USER" --auto-repair --optimize "$DB_NAME" 2>/dev/null | tee -a "$LOG_FILE"
            echo "✓ Database optimization process completed" | tee -a "$LOG_FILE"
        else
            echo "No tables found in database. Skipping optimization." | tee -a "$LOG_FILE"
        fi
    else
        echo "Database optimization skipped by user choice" | tee -a "$LOG_FILE"
    fi
fi

# Step 11: Final Verification
if [ "$DRYRUN" = false ]; then
    if [ "$EXISTING_PREFIX" != "$BACKUP_PREFIX" ]; then
        UPDATED_PREFIX=$(grep -oP "\\\$table_prefix\s*=\s*['\"]\K[^'\"]+(?=['\"]\s*;)" "$WP_INSTALL_DIR/wp-config.php")
        if [ "$UPDATED_PREFIX" != "$BACKUP_PREFIX" ]; then
            echo "╔════════════════════════════════════════════════════════════════╗"
            echo "║                  IMPORTANT CONFIGURATION NOTE                  ║"
            echo "╚════════════════════════════════════════════════════════════════╝"
            echo "⚠️  The website will not work until you update the table prefix!"
            printf "  Current prefix:  %-30s\n" "$UPDATED_PREFIX"
            printf "  Required prefix: %-30s\n" "$BACKUP_PREFIX"
            echo "File to edit: $WP_INSTALL_DIR/wp-config.php (around line 70)"
        else
            echo "✓ Table prefix configuration verified" | tee -a "$LOG_FILE"
        fi
    fi
    echo "Restore process completed!" | tee -a "$LOG_FILE"
    echo "Please verify the site functionality at: https://$DOMAIN" | tee -a "$LOG_FILE"
fi

# Step 12: Cleanup
if [ "$DRYRUN" = false ]; then
    read -t 60 -p "Clean up temporary files and move backup archive? [Y/n] " USER_INPUT || true
    USER_INPUT=${USER_INPUT:-yes}
    if [[ "$USER_INPUT" =~ ^[Yy]es$|^[Yy]$|^$ ]]; then
        if [ -f "$TEMP_DIR/$LATEST_BACKUP" ]; then
            mv "$TEMP_DIR/$LATEST_BACKUP" "$RESTORE_DIR/" 2>/dev/null && echo "✓ Backup archive moved to restore directory" | tee -a "$LOG_FILE" || echo "Warning: Failed to move backup archive" | tee -a "$LOG_FILE"
        fi
        cleanup_tmp_files
        echo "All restore files are located in: $RESTORE_DIR"
        echo "Directory is protected from public access via .htaccess"
        echo "You can safely delete the restore directory after verifying the site."
    else
        echo "Cleanup skipped. Temporary files at $TEMP_DIR" | tee -a "$LOG_FILE"
    fi
else
    echo "[Dry Run] Would clean up temporary files and move the backup archive." | tee -a "$LOG_FILE"
fi