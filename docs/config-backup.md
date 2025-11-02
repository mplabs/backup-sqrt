# Duply Configuration Backup Workflow

## Overview
The `backup-configs` helper (installed via `install.sh`, see `docs/install.md`) packages each configured duply profile, encrypts the archive with symmetric GPG, then ships it to your rsync endpoint. Per-profile definitions live under `config/profiles/` so you can track them in version control and deploy to servers (e.g., `/etc/config-backup/profiles/`).

## Prerequisites
- Run the script as `root`; it needs to read user-owned directories and preserve ownership.
- Install `gpg`, `tar`, `rsync`, `sha256sum`, and `curl` (only when using Uptime Kuma webhooks).
- Authenticate the 1Password CLI (`op`) if you use `PASSPHRASE_SECRET` entries. Export a session with `eval "$(op signin --account <subdomain>)"` before cron executes, or use a service account with an item-specific token.

## Configuring Profiles
1. Copy `config/profiles/example.conf` for each duply profile.
2. Update key/value pairs:
   - `profile_name` – identifier baked into bundle names.
   - `profile_user` – Unix user that owns the duply profile (case-sensitive).
   - `duply_dir` – absolute path to the profile directory (e.g., `/home/user/.duply/<profile>`).
   - `rsync_target` – remote rsync destination (`user@host:/path/to/store/`).
   - `passphrase_secret` (preferred) or `passphrase_file` – where to load the symmetric password.
   - `compression` – `gzip` (default), `zstd`, or `none`.
   - Repeat `include=` lines for SSH keys, helper scripts, or other assets to ship with the profile.
   - Optional `cron_reference` and `notes` entries appear in the manifest for auditability.
3. Avoid shell metacharacters; wrap values with spaces in quotes or escape them (`cron_reference="15 2 * * * user cmd"`). For 1Password references that contain spaces, either quote the value or encode spaces as `%20`.
4. Store the symmetric passphrase in 1Password at the exact reference path you configure.
5. Place the completed `.conf` files under `/etc/config-backup/profiles/` and install the script at `/usr/local/sbin/backup-configs.sh` (root-readable only).
6. Temporarily disable a profile by renaming it to `.conf.disabled`; the script logs the skip so you can see which profiles are parked.

## Running the Backup
- Manual run: `CONFIG_PROFILES_DIR=/etc/config-backup/profiles /usr/local/sbin/backup-configs`.
- Cron example (`/etc/cron.d/config-backup`):
  ```
  15 2 * * * root CONFIG_PROFILES_DIR=/etc/config-backup/profiles \
    UPTIME_KUMA_WEBHOOK=https://uptime.example.com/api/push/<token> \
    /usr/local/sbin/backup-configs
  ```
- Successful runs emit `configs-<profile>-<timestamp>.tar.gz.gpg` plus a `.sha256` file to your rsync target. Failures trigger the webhook (status `down`) with an error summary.
- The script enforces a lock (`/var/lock/backup-configs.lock`) to prevent overlapping runs; adjust with `LOCK_FILE=/path` if needed.

## Restoring a Profile
1. Fetch the encrypted bundle from the rsync archive.
2. Retrieve the matching passphrase from 1Password (`op read ...`).
3. Verify integrity: `sha256sum -c configs-<profile>.tar.*.gpg.sha256`.
4. Decrypt: `gpg --batch --yes --pinentry-mode loopback --passphrase "$PASSPHRASE" -o configs.tar.* -d configs.tar.*.gpg`.
5. Extract depending on compression:
   - `.tar.gz`: `tar -xzf configs.tar.gz`
   - `.tar.zst`: `zstd -d configs.tar.zst && tar -xf configs.tar`
   - `.tar`: `tar -xf configs.tar`
6. Restore directories (run as root, then fix ownership):  
   - Copy `duply/<profile>` back to `~profile_user/.duply/<profile>/`, then `chown -R profile_user:profile_user` as required.  
   - Reinstall `includes/` assets (SSH keys, scripts, etc.) to original locations and set restrictive permissions (`chmod 600` for private keys).
7. Import GPG keys when included: `gpg --import < private-key-file` (run as the owning user).
8. Validate by running `duply <profile> status` or a targeted restore against an existing archive.

## Key Rotation & Maintenance
- Rotate symmetric passphrases and corresponding 1Password entries whenever SSH/GPG keys change or quarterly at minimum.
- Update the profile config when adding new include paths; the next cron run will pick up changes automatically.
- Spot-check archives quarterly: decrypt the latest bundle and ensure paths and manifests are current.
- Monitor webhook alerts in Uptime Kuma; investigate repeated failures (often missing `op` session or permission changes).
- After a rotation or restore test, securely delete decrypted tarballs and manifests (`shred` or `srm`) if policy requires.
- For unattended 1Password access, create a service account with vault-level privileges, store its secret in an environment file readable only by root, and renew `op signin` sessions before cron (e.g., via `systemd` timer with `EnvironmentFile=/root/.config/op/session.env`).
