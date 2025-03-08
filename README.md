# wpbackup-restore

A collection of scripts to backup and restore WordPress sites using Rclone and S3-compatible storage.

## Features
- **Backup**: Backs up WordPress sites (database, `wp-content`, `wp-config.php`) and uploads to S3-compatible storage.
- **Restore**: Restores WordPress sites from backups with database and file options.
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
Edit the Rclone configuration file with your S3-compatible storage credentials:
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
  - Full restore: `wprestore`
  - Dry run: `wprestore -dryrun`

## Cron Job
A cron job is set to run `wpbackup` daily at 2:00 AM, logging to `/var/log/wpbackup.log`.
- **Check Cron Job**: `crontab -l` (should show `0 2 * * * /usr/local/bin/wpbackup >> /var/log/wpbackup.log 2>&1`)
- **Modify Time** (e.g., to 3:00 AM): `crontab -e`, update to `0 3 * * * /usr/local/bin/wpbackup >> /var/log/wpbackup.log 2>&1`, save and exit.
- **Manual Add (if needed)**: `(crontab -l 2>/dev/null; echo "0 2 * * * /usr/local/bin/wpbackup >> /var/log/wpbackup.log 2>&1") | crontab -`

## Updating Scripts
To update to the latest version, use the installed `update-wpscripts` command:
```bash
update-wpscripts
```
- **Note**: This updates `wpbackup` and `wprestore` in `/usr/local/bin` using the latest tarball. If it fails (e.g., due to a corrupted setup), re-run the installation:
  ```bash
  rm -rf /opt/wpbackup-restore && mkdir -p /opt/wpbackup-restore && curl -L https://github.com/shrocktech/wpbackup-restore/archive/refs/heads/main.tar.gz | tar -xz -C /opt/wpbackup-restore --strip-components=1 && chmod +x /opt/wpbackup-restore/install.sh /opt/wpbackup-restore/update.sh /opt/wpbackup-restore/wpbackup.sh /opt/wpbackup-restore/wprestore.sh && /opt/wpbackup-restore/install.sh
  ```

## Configuration Options
- **Backup Directory**: Defaults to `/var/www`. Override with: `BASE_DIR=/custom/path wpbackup`
- **Restore Directory**: Defaults to `/var/www`. Override with: `WP_BASE_PATH=/custom/path wprestore`
- **Logs**: `/var/log/wpbackup.log` (backup), `/var/log/wprestore.log` (restore)

## Notes
- **Security**: Do not commit `/root/.config/rclone/rclone.conf`.
- **Restore Verification**: After restoring, verify at `https://<domain>` and check `wp-config.php` for table prefix issues.

## Troubleshooting
- Check logs if a script fails: `cat /var/log/wpbackup.log` or `cat /var/log/wprestore.log`
- Ensure dependencies and Rclone are configured correctly.
- If the tarball download fails, verify the URL or internet connection.

## Contributing
Make changes locally and upload to a new GitHub repository if desired.