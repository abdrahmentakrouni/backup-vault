# Changelog

All notable changes to backup-vault are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/) and the
project adheres to [Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-09-16

First stable release.

### Added

- Backup engine: nightly file snapshots plus MySQL/MariaDB database dumps,
  compressed and encrypted in one streaming pipeline (no plaintext at rest).
- AES-256-CBC encryption with PBKDF2 key stretching (300,000 iterations);
  passphrases are read from a protected file or the environment, never argv.
- Off-site replication with three vault drivers: S3-compatible object storage
  (rclone), an append-only SSH vault (hardened ingest wrapper included) and a
  plain directory target for NAS or USB disks.
- Grandfather-father-son retention (7 daily, 4 weekly, 12 monthly by default)
  with promotion and pruning on both the local vault and the remote copy.
- Ransomware canary tripwire: decoy business files are checksummed before
  every run; if their hashes drift, the backup aborts with exit code 42 and
  fires an alert instead of archiving encrypted junk over good backups.
- Integrity verification (`vault.sh verify`) and a one-command disaster
  recovery drill (`vault.sh drill`) with measured restore time.
- Health audit (`vault.sh status`): backup age vs RPO, encryption spot check,
  off-site copy check, schedule check, vault disk usage, last drill date.
- Alerting hooks: webhook notifications on failures and tripwire events, plus
  a heartbeat file for dead-man-switch monitoring.
- One-command installer (`vault.sh install`) writing cron entries or systemd
  timers.
- Demo stack: docker compose with a company server, a MariaDB database and an
  isolated MinIO S3 vault; CI simulates a full ransomware incident on every
  push (backup, encryption check, tripwire, destruction, restore, byte-for-byte
  comparison).
