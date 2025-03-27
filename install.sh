#!/bin/bash

# install.sh - Installs Rclone, scripts, and sets up cron job for backups

set -e

# Define the script directory
SCRIPT_DIR="/opt/wpbackup-restore"

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
    cp "$SCRIPT_DIR/rclone.conf.example" "$RCLONE_CONF_FILE"
    echo "Rclone configuration file copied to $RCLONE_CONF_FILE."
fi

# 3. Install scripts
INSTALL_DIR="/usr/local/bin"
echo "Listing files in $SCRIPT_DIR for debugging:"
ls -l "$SCRIPT_DIR"

for script in wpbackup wprestore cleanup update; do
    if [ ! -f "$SCRIPT_DIR/${script}.sh" ]; then
        echo "Error: ${script}.sh not found in $SCRIPT_DIR."
        exit 1
    fi

    if [ "$script" = "update" ]; then
        cp "$SCRIPT_DIR/${script}.sh" "$INSTALL_DIR/update-wpscripts"
        chmod +x "$INSTALL_DIR/update-wpscripts"
        echo "Installed update-wpscripts to $INSTALL_DIR/update-wpscripts."
    elif [ "$script" = "cleanup" ]; then
        cp "$SCRIPT_DIR/${script}.sh" "$INSTALL_DIR/wpcleanup"
        chmod +x "$INSTALL_DIR/wpcleanup"
        echo "Installed wpcleanup to $INSTALL_DIR/wpcleanup."
    else
        cp "$SCRIPT_DIR/${script}.sh" "$INSTALL_DIR/$script"
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

# Output the nano command first, followed by other messages
echo "Installation completed successfully."
echo "Next steps:"
echo "1. nano $RCLONE_CONF_FILE"
echo "2. Test the backup script: wpbackup -dryrun"
echo "3. Test the restore script: wprestore -dryrun"
echo "4. Test the cleanup script: wpcleanup -dryrun"