#!/bin/bash

# update.sh - Updates the installed wpbackup and wprestore scripts from the GitHub repository

set -e

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root. Use sudo."
    exit 1
fi

# Check for required tools
if ! command -v git &> /dev/null; then
    echo "Error: git is not installed. Please install it and try again."
    exit 1
fi

# Define repository and install directories
REPO_DIR="/opt/WPBACKUP-RESTORE"
INSTALL_DIR="/usr/local/bin"

# Verify repository directory exists
if [ ! -d "$REPO_DIR/.git" ]; then
    echo "Error: Repository not found at $REPO_DIR. Please clone it first with:"
    echo "  git clone https://github.com/your-username/WPBACKUP-RESTORE.git $REPO_DIR"
    exit 1
fi

# Pull the latest changes
echo "Updating repository at $REPO_DIR..."
cd "$REPO_DIR"
if ! git pull; then
    echo "Error: Failed to pull updates from the repository. Check your internet connection or repository status."
    exit 1
fi

# Update scripts
for script in wpbackup wprestore; do
    if [ ! -f "${script}.sh" ]; then
        echo "Error: ${script}.sh not found in the repository after update."
        exit 1
    fi
    cp "${script}.sh" "$INSTALL_DIR/$script"
    chmod +x "$INSTALL_DIR/$script"
    echo "Updated $script in $INSTALL_DIR/$script."
done

echo "Scripts updated successfully. You can now use wpbackup and wprestore with the latest changes."