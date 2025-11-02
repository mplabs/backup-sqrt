# backup-sqrt

Need a reliable way to back up all those carefully crafted duply configs (plus the awkward SSH keys, helper scripts, and secret notes that live beside them)? **backup-sqrt** bundles the lot, seals it with GPG, and ships it off via rsync—because “I forgot the cronjob” is not an acceptable postmortem.

## What’s in the box?
- A friendly shell script (`backup-configs`) that reads declarative profile files and does the boring chores: rsyncs your duply setups, archives them, encrypts with AES256, checksums the results, and drops bundles at your storage target.
- A one-liner installer that pulls the latest release, installs the script and docs, seeds `/etc/config-backup/`, and leaves you with a ready-to-edit cron template.
- Docs and examples so you don’t have to reverse-engineer your own backups at 3 a.m.

## Quickstart (a.k.a. the “just do it” section)
```bash
curl -sSfL https://raw.githubusercontent.com/mplabs/backup-sqrt/main/install.sh | sudo bash
```
1. Copy `/etc/config-backup/profiles/example.conf` to something meaningful, fill in the values, and decide whether the passphrase lives in 1Password (`PASSPHRASE_SECRET`) or on disk (`PASSPHRASE_FILE`).
2. Run `sudo /usr/local/sbin/backup-configs` once to make sure the bundles land where they should.
3. Update `/etc/cron.d/backup-configs` with your schedule (and optional Uptime Kuma webhook), then uncomment the line to let it run on autopilot.

## Why you might like it
- Keeps duply profiles versioned separately from the rest of your infra, so you can reuse them across hosts.
- Encrypts everything by default; no more plain-text secrets lying around in tarballs.
- Plays nice with 1Password CLI for secret management, but doesn’t force you to use it.

## Where to look next
- `docs/install.md` for a slower walkthrough.
- `docs/config-backup.md` for the “what exactly is this script doing?” crowd.
- `scripts/backup-configs.sh` if you enjoy reading Bash with your morning coffee.

That’s it. Install it, point it at your duply profiles, and relax knowing future-you won’t have to reconstruct backup configs from hazy memories.
