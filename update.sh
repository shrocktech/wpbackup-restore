#!/bin/bash

# update.sh - Updates the installed wpbackup, wprestore, and wpcleanup scripts from the GitHub tarball

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

# Define install directory and temporary directory
INSTALL_DIR="/usr/local/bin"
TEMP_DIR=$(mktemp -d)

# Download and extract the latest tarball
echo "Downloading the latest version from GitHub..."
if ! curl -L https://github.com/shrocktech/wpbackup-restore/archive/refs/heads/main.tar.gz | tar -xz -C "$TEMP_DIR" --strip-components=1; then
    echo "Error: Failed to download or extract the tarball. Please check your internet connection or the repository."
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Update scripts
for script in wpbackup wprestore wpcleanup; do
    if [ ! -f "$TEMP_DIR/${script}.sh" ]; then
        echo "Error: ${script}.sh not found in the downloaded tarball."
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    
    # Use the correct destination name for each script
    if [ "$script" = "wpcleanup" ]; then
        cp "$TEMP_DIR/cleanup.sh" "$INSTALL_DIR/$script"
    else
        cp "$TEMP_DIR/${script}.sh" "$INSTALL_DIR/$script"
    fi
    
    chmod +x "$INSTALL_DIR/$script"
    echo "Updated $script in $INSTALL_DIR/$script."
done

# Clean up temporary directory
rm -rf "$TEMP_DIR"

echo "Scripts updated successfully. You can now use wpbackup, wprestore, and wpcleanup with the latest changes."