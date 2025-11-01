# Installing backup-sqrt

## Quick Install
Run the installer as root (or via `sudo`). It fetches the latest GitHub release, installs binaries and docs, and seeds configuration directories.

```bash
curl -sSfL https://raw.githubusercontent.com/mplabs/backup-sqrt/main/install.sh | sudo bash
```

Environment variables influence the installer:
- `VERSION` – use a specific tag (e.g., `VERSION=v1.2.3`).
- `INSTALL_PREFIX`, `BIN_DIR`, `CONFIG_DIR`, `PROFILES_DIR`, `CRON_FILE` – override install paths if needed.

## What the Installer Does
- Ensures core dependencies (`curl`, `tar`, `gzip`, `gpg`, `rsync`, `sha256sum`) are present. On Debian-based systems it uses `apt-get` to install missing packages.
- Downloads the latest `backup-sqrt` release archive and verifies the checksum when available.
- Installs the runtime script to `/usr/local/sbin/backup-configs` (with a compatibility symlink `backup-configs.sh`).
- Copies documentation to `/usr/local/share/doc/backup-sqrt/`.
- Seeds `/etc/config-backup/profiles/example.conf` if it does not exist and creates `/etc/config-backup/passphrases/`.
- Drops a disabled cron template at `/etc/cron.d/backup-configs`; edit and uncomment once configuration is ready.

## Post-Install Checklist
1. Create per-profile `.conf` files in `/etc/config-backup/profiles/` using the provided example.
2. Store symmetric passphrases in 1Password or `/etc/config-backup/passphrases/`.
3. Test a manual run:
   ```bash
   CONFIG_PROFILES_DIR=/etc/config-backup/profiles /usr/local/sbin/backup-configs
   ```
4. Update `/etc/cron.d/backup-configs` with the desired schedule and environment variables (e.g., `UPTIME_KUMA_WEBHOOK`) before enabling.
5. Commit configuration files to infrastructure-as-code tooling or secure backups for reproducibility.
