# WPBACKUP-RESTORE

A collection of scripts to backup and restore WordPress sites using Rclone and IDrive S3-compatible storage.

## Features
- **Backup**: Backs up WordPress sites (database, `wp-content`, `wp-config.php`) and uploads to IDrive.
- **Restore**: Restores WordPress sites from backups with database and file options.
- **Retention Policy**: Manages backup retention (daily, weekly, monthly).
- **Easy Updates**: Update scripts with a single command.

## Requirements
- Ubuntu (or a compatible Linux distribution)
- Root or sudo privileges
- `rclone`, `tar`, `mysqldump`, `mysql`, `rsync`, `pv`, `git`, and `curl` (installed automatically or manually)

## Installation

Follow these steps to set up the WPBACKUP-RESTORE tools:

1. **Clone the Repository**:
   Copy and paste the following command to clone the repository to `/opt/WPBACKUP-RESTORE`:
   ```bash
   git clone https://github.com/your-username/WPBACKUP-RESTORE.git /opt/WPBACKUP-RESTORE
   cd /opt/WPBACKUP-RESTORE
   ```

2. **Run the Install Script**:
   Copy and paste the following command to install Rclone, the scripts, and set up the initial configuration:
   ```bash
   sudo ./install.sh
   ```
   - This will:
     - Install Rclone if not already present.
     - Copy `rclone.conf.example` to `/root/.config/rclone/rclone.conf`.
     - Install `wpbackup`, `wprestore`, and `update-wpscripts` to `/usr/local/bin`.
     - Set a cron job for daily backups (see below).

3. **Configure Rclone with IDrive Credentials**:
   Copy and paste the following command to edit the Rclone configuration file with your IDrive credentials:
   ```bash
   sudo nano /root/.config/rclone/rclone.conf
   ```
   - Replace the placeholder values in the file with your IDrive details. The file should look like this (update with your actual access key, secret key, and endpoint):
     ```plaintext
     [IDrive]
     type = s3
     provider = Other
     env_auth = false
     access_key_id = your_access_key
     secret_access_key = your_secret_key
     endpoint = your_endpoint_url
     no_check_bucket = true

     [IDriveBackup]
     type = alias
     remote = IDrive:contabosites/backups
     ```
   - Save the file (Ctrl+O, Enter, Ctrl+X) and exit.

4. **Verify the Setup**:
   Copy and paste the following commands to test the backup and restore scripts in dry-run mode:
   ```bash
   wpbackup -dryrun
   wprestore -dryrun
   ```
   - Ensure no errors are reported and that the scripts connect to your IDrive storage.

## Usage

### Backup a WordPress Site
- Run a full backup:
  ```bash
  sudo wpbackup
  ```
- Test without making changes (dry run):
  ```bash
  sudo wpbackup -dryrun
  ```

### Restore a WordPress Site
- Run a restore (follow the prompts to enter the domain and choose options):
  ```bash
  sudo wprestore
  ```
- Test without making changes (dry run):
  ```bash
  sudo wprestore -dryrun
  ```

## Setting Up a Cron Job for Daily Backups

The `install.sh` script automatically sets up a cron job to run `wpbackup` daily at 2:00 AM, logging output to `/var/log/wpbackup.log`. To verify or modify the cron job:

1. **Check the Current Cron Job**:
   Copy and paste the following command to view your crontab:
   ```bash
   crontab -l
   ```
   - You should see a line like this:
     ```plaintext
     0 2 * * * /usr/local/bin/wpbackup >> /var/log/wpbackup.log 2>&1
     ```
     - This runs `wpbackup` every day at 2:00 AM.

2. **Modify the Cron Job (Optional)**:
   - If you want to change the time (e.g., to 3:00 AM), edit the crontab:
     ```bash
     crontab -e
     ```
   - Update the line to, for example:
     ```plaintext
     0 3 * * * /usr/local/bin/wpbackup >> /var/log/wpbackup.log 2>&1
     ```
   - Save and exit the editor.

3. **Manually Add the Cron Job (If Needed)**:
   - If the cron job wasn’t set up, add it manually:
     ```bash
     (crontab -l 2>/dev/null; echo "0 2 * * * /usr/local/bin/wpbackup >> /var/log/wpbackup.log 2>&1") | crontab -
     ```

## Updating Scripts

To update `wpbackup` and `wprestore` to the latest version from the GitHub repository:

- Copy and paste the following command from any directory:
  ```bash
  sudo update-wpscripts
  ```
  - This pulls the latest changes and updates the installed scripts in `/usr/local/bin`.

## Configuration

- **Rclone Configuration**: Edit `/root/.config/rclone/rclone.conf` with your IDrive credentials (see Step 3 above).
- **Backup Directory**: Defaults to `/var/www`. Override with:
  ```bash
  BASE_DIR=/custom/path wpbackup
  ```
- **Restore Directory**: Defaults to `/var/www`. Override with:
  ```bash
  WP_BASE_PATH=/custom/path wprestore
  ```
- **Logs**: Backup logs are written to `/var/log/wpbackup.log`, and restore logs to `/var/log/wprestore.log`.

## Notes
- **Security**: Never commit `/root/.config/rclone/rclone.conf` to the repository. Add it to `.gitignore` if needed:
  ```bash
  echo "/root/.config/rclone/rclone.conf" >> .gitignore
  git add .gitignore
  git commit -m "Ignore rclone.conf"
  git push
  ```
- **Backup Retention**: `wpbackup` automatically manages retention (7 days daily, 28 days weekly, 90 days monthly).
- **Restore Verification**: After restoring, verify the site at `https://<domain>` and check for table prefix mismatches in `wp-config.php`.

## Troubleshooting
- If a script fails, check the logs:
  ```bash
  cat /var/log/wpbackup.log
  cat /var/log/wprestore.log
  ```
- Ensure all dependencies are installed and Rclone is configured correctly.

## Contributing
Feel free to fork this repository, make improvements, and submit pull requests. Replace `your-username` in the clone URL with the actual GitHub username hosting this repository.
