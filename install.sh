#!/bin/bash

# install.sh - Installs Rclone, scripts, and sets up cron job for backups

set -e

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root."
    exit 1
fi

# Check for required tools
for cmd in curl tar; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: $cmd is not installed. Please install it and try again."
        exit 1
    fi
done

# 1. Install Rclone
if ! command -v rclone &> /dev/null; then
    echo "Installing Rclone..."
    curl https://rclone.org/install.sh | bash
else
    echo "Rclone is already installed."
fi

# 2. Install Rclone configuration file
RCLONE_CONF_DIR="/root/.config/rclone"
RCLONE_CONF_FILE="$RCLONE_CONF_DIR/rclone.conf"
if [ -f "$RCLONE_CONF_FILE" ]; then
    echo "Rclone configuration file already exists at $RCLONE_CONF_FILE. Skipping copy."
else
    mkdir -p "$RCLONE_CONF_DIR"
    cp rclone.conf.example "$RCLONE_CONF_FILE"
    echo "Rclone configuration file copied to $RCLONE_CONF_FILE."
    echo "Please edit $RCLONE_CONF_FILE with your S3-compatible storage credentials (e.g., replace placeholders with your access keys, secret key, and endpoint)."
    echo "Example configuration for an S3-compatible provider:"
    echo "  [S3Provider]"
    echo "  type = s3"
    echo "  provider = Other"
    echo "  env_auth = false"
    echo "  access_key_id = your_access_key"
    echo "  secret_access_key = your_secret_key"
    echo "  endpoint = your_endpoint_url"
    echo "  no_check_bucket = true"
    echo "  [S3Backup]"
    echo "  type = alias"
    echo "  remote = S3Provider:your-backup-directory"
    echo "Use 'nano $RCLONE_CONF_FILE' to make these changes."
fi

# 3. Install scripts
INSTALL_DIR="/usr/local/bin"
echo "Listing files in current directory for debugging:"
ls -l
for script in wpbackup wprestore update; do
    if [ ! -f "${script}.sh" ]; then
        echo "Error: ${script}.sh not found in the repository."
        exit 1
    fi
    if [ "$script" = "update" ]; then
        cp "${script}.sh" "$INSTALL_DIR/update-wpscripts"
        chmod +x "$INSTALL_DIR/update-wpscripts"
        echo "Installed update-wpscripts to $INSTALL_DIR/update-wpscripts."
    else
        cp "${script}.sh" "$INSTALL_DIR/$script"
        chmod +x "$INSTALL_DIR/$script"
        echo "Installed $script to $INSTALL_DIR/$script."
    fi
done

# 4. Set cron job for daily backups
CRON_LOG="/var/log/wpbackup.log"
CRON_JOB="0 2 * * * /usr/local/bin/wpbackup >> $CRON_LOG 2>&1"
if crontab -l 2>/dev/null | grep -q "/usr/local/bin/wpbackup"; then
    echo "Cron job already exists for wpbackup. Skipping."
else
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
    echo "Cron job set to run wpbackup daily at 2:00 AM. Logs will be written to $CRON_LOG."
fi

echo "Installation completed successfully."
echo "Next steps:"
echo "1. Edit $RCLONE_CONF_FILE with your S3-compatible storage credentials using 'nano $RCLONE_CONF_FILE'."
echo "2. Test the backup script: wpbackup -dryrun"
echo "3. Test the restore script: wprestore -dryrun"