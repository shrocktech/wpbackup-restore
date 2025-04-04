# wpbackup-restore

A collection of scripts to backup and restore WordPress sites using Rclone and S3-compatible storage.

## Features
- **Backup**: Backs up WordPress sites (database, `wp-content`, `wp-config.php`) and uploads to S3-compatible storage.
- **Local Backup**: Keeps recent backups locally for faster restores.
- **Restore**: Restores WordPress sites from either local or S3 backups with database and file options.
- **Object Cache Cleanup**: Utility to remove `object-cache` files that may cause issues after migrations or restores.
- **Retention Policy**: Manages backup retention (7 days daily, 28 days weekly, 90 days monthly).
- **Easy Updates**: Update scripts with a single command.

## Requirements
- Ubuntu (or compatible Linux distribution)
- Logged in as root (no sudo required)
- `curl`, `tar`, `rclone`, `mysqldump`, `mysql`, `rsync`, `pv`

## Installation
Copy and paste the following command to download, set up, and install the scripts in `/opt/wpbackup-restore`, with scripts copied to `/usr/local/bin`:
```bash
mkdir -p /opt/wpbackup-restore && curl -L https://github.com/shrocktech/wpbackup-restore/archive/refs/heads/main.tar.gz | tar -xz -C /opt/wpbackup-restore --strip-components=1 && chmod +x /opt/wpbackup-restore/install.sh /opt/wpbackup-restore/update.sh /opt/wpbackup-restore/wpbackup.sh /opt/wpbackup-restore/wprestore.sh && /opt/wpbackup-restore/install.sh
```
- This downloads the latest files, sets permissions, installs Rclone (if needed), copies `rclone.conf.example` to `/root/.config/rclone/rclone.conf`, installs `wpbackup`, `wprestore`, and `update-wpscripts` to `/usr/local/bin`, and sets a cron job for daily backups at 2:00 AM.

## Configuration
First make sure the config file exists
```bash
mkdir -p /root/.config/rclone
```

Then edit the Rclone configuration file with your S3-compatible storage credentials:
```bash
nano /root/.config/rclone/rclone.conf
```
Update with your details (replace placeholders):
```plaintext
[MyS3Provider]
type = s3
provider = Other
env_auth = false
access_key_id = your_access_key
secret_access_key = your_secret_key
endpoint = your_endpoint_url
no_check_bucket = true

[S3Backup]
type = alias
remote = MyS3Provider:bucketname
```
Save (Ctrl+O, Enter, Ctrl+X) and exit.

- **Test Rclone Configuration**: Verify connectivity with your S3-compatible storage:
  ```bash
  rclone lsd MyS3Provider:
  ```
  - This should list the directories in your storage. If it fails, check your credentials and endpoint in `/root/.config/rclone/rclone.conf`.

## Usage
- **Backup a Site**:
  - Full backup: `wpbackup`
  - Dry run: `wpbackup -dryrun`
- **Restore a Site**:
  - Interactive restore: `wprestore`
  - Dry run: `wprestore -dryrun`

## Local Backups
- **Storage Location**: Local backups are stored in `/var/backups/wordpress_backups/`
- **Retention**: Only the most recent backup (last 24 hours) is kept locally
- **Custom Path**: Override with `LOCAL_BACKUP_DIR=/custom/path wpbackup`

## Restore Options
When restoring, you can choose from:
1. **Local Backup Source** (default): Faster restore from local backups
2. **Remote S3 Backup**: Useful when local backups aren't available
3. **Database Only or Full Restore**: Choose whether to restore just the database or the complete site

## Cron Job
A cron job is set to run `wpbackup` daily at 2:00 AM, logging to `/var/log/wpbackup.log`.
- **Check Cron Job**: `crontab -l` (should show `0 2 * * * /usr/local/bin/wpbackup >> /var/log/wpbackup.log 2>&1`)
- **Modify Time** (e.g., to 3:00 AM): `crontab -e`, update to `0 3 * * * /usr/local/bin/wpbackup >> /var/log/wpbackup.log 2>&1`, save and exit.
- **Manual Add (if needed)**: `(crontab -l 2>/dev/null; echo "0 2 * * * /usr/local/bin/wpbackup >> /var/log/wpbackup.log 2>&1") | crontab -`

## WP Cleanup
The `wpcleanup` utility removes files from WordPress installations that are no longer needed:

- Removes all files and directories for specified domains
- Cleans up backup archives and restore directories
- Helps reclaim disk space after site decommissioning

Usage: `wpcleanup` or `wpcleanup domainname.com`

Cleanup operations are logged to `/var/log/wpsitecleanup.log`.

## Updating Scripts
To update to the latest version, use the installed `update-wpscripts` command:
```bash
update-wpscripts
```
- **Note**: This updates `wpbackup` and `wprestore` in `/usr/local/bin` using the latest tarball. If it fails (e.g., due to a corrupted setup), re-run the installation:
  ```bash
  rm -rf /opt/wpbackup-restore && mkdir -p /opt/wpbackup-restore && curl -L https://github.com/shrocktech/wpbackup-restore/archive/refs/heads/main.tar.gz | tar -xz -C /opt/wpbackup-restore --strip-components=1 && chmod +x /opt/wpbackup-restore/install.sh /opt/wpbackup-restore/update.sh /opt/wpbackup-restore/wpbackup.sh /opt/wpbackup-restore/wprestore.sh /opt/wpbackup-restore/cleanup.sh && /opt/wpbackup-restore/install.sh
  ```

## Configuration Options
- **Backup Directory**: Defaults to `/var/www`. Override with: `BASE_DIR=/custom/path wpbackup`
- **Restore Directory**: Defaults to `/var/www`. Override with: `WP_BASE_PATH=/custom/path wprestore`
- **Local Backup Storage**: Defaults to `/var/backups/wordpress_backups`. Override with: `LOCAL_BACKUP_DIR=/custom/path wpbackup` or `LOCAL_BACKUP_DIR=/custom/path wprestore`
- **Logs**: Per-site logs are included in each backup archive

## Notes
- **Security**: Do not commit `/root/.config/rclone/rclone.conf`.
- **Restore Verification**: After restoring, verify at `https://<domain>` and check `wp-config.php` for table prefix issues.
- **Database Format**: Database files are named in the format `domainprefix_db_YYYY-MM-DD.sql` for compatibility.

## Troubleshooting
- Check backup logs in the backup archives or cron job output
- Ensure dependencies and Rclone are configured correctly.
- If the tarball download fails, verify the URL or internet connection.
- To remove a restoration directory: `rm -rf /var/www/domainname/wprestore_MMDDYYYY`

## Contributing
Make changes locally and upload to a new GitHub repository if desired.
