# backup-vault

[![CI](https://github.com/abdrahmentakrouni/backup-vault/actions/workflows/ci.yml/badge.svg)](https://github.com/abdrahmentakrouni/backup-vault/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/abdrahmentakrouni/backup-vault)](https://github.com/abdrahmentakrouni/backup-vault/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Shell](https://img.shields.io/badge/Shell-Bash-4EAA25)
![Encryption](https://img.shields.io/badge/Encryption-AES--256-red)

**Ransomware-resilient automated backup and disaster recovery for Linux
servers.** Nightly cron backups of files and databases, AES-256 encrypted,
compressed, shipped off-site to an isolated vault, rotated on a
grandfather-father-son schedule - with a ransomware canary tripwire and a
disaster drill that CI runs on every push.

## Why this exists

Ransomware is not a hacker story, it is a business continuity story: when a
company's servers get encrypted, the only real way out is a clean, recent,
off-site backup. Most "backups" fail exactly when they are needed - they are
not encrypted (stolen backups leak), they are reachable by the same malware
that hit the server, nobody tested the restore, or the backup job died weeks
ago and nobody noticed. backup-vault is built against all four failure modes:

| Failure mode | Control |
|---|---|
| Backup job dies silently | heartbeat file + webhook alerts + `status` audit (backup age vs RPO) |
| Malware reaches the backups | append-only SSH vault, S3 Object Lock support, tripwire stops compromised runs |
| Backup archives encrypted junk over good copies | ransomware canary tripwire aborts the run with exit 42 |
| Restore never tested | one-command `drill` with measured RTO + CI disaster simulation |
| Stolen backup = stolen data | AES-256-CBC, PBKDF2 (300k iterations), passphrase never in argv |
| Silent corruption | SHA-256 manifest per archive + `verify` command |

## Features

- **Automated schedule** - cron or systemd timers installed by `vault.sh install`
- **Files + databases** - rsync-staged file snapshots and `mysqldump`
  (`--single-transaction`, consistent InnoDB snapshots) in one archive
- **Encrypted and compressed in one stream** - the plaintext never touches the
  disk: `tar | gzip | openssl aes-256-cbc`
- **3-2-1 off-site copy** - three vault drivers: S3-compatible object storage
  (rclone), append-only SSH vault host, or a plain NAS/USB directory
- **Grandfather-father-son retention** - 7 daily / 4 weekly / 12 monthly by
  default, pruned locally and remotely
- **Ransomware canary tripwire** - decoy business files are checksummed before
  every run; drift aborts the backup before it can destroy the last good copy
- **Monitoring hooks** - JSON webhook alerts on failures and tripwires,
  heartbeat file for dead-man-switch monitoring
- **Health audit** - `vault.sh status` reports backup age vs RPO, encryption
  spot check, off-site presence, schedule, last drill, disk pressure
- **Disaster drill** - `vault.sh drill` test-restores the newest archive and
  measures the real RTO

## Quick demo (60 seconds)

```bash
git clone https://github.com/abdrahmentakrouni/backup-vault.git
cd backup-vault
docker compose up -d --wait      # company server + MariaDB + isolated MinIO vault
docker compose exec primary bash /opt/backup-vault/tests/local-demo.sh
```

The demo script backs up the "company server" (files + MySQL dump), corrupts
the data like ransomware would, restores everything from the encrypted vault
and proves it byte-for-byte. Then destroy the whole stack with
`docker compose down -v` when you are done.

The CI pipeline runs the full version of this on every push:

```
backup -> encryption proof -> retention -> tripwire test ->
RANSOMWARE (files scrambled + database dropped) ->
restore from vault -> byte-for-byte verification -> health audit
```

## Production install

```bash
sudo bash scripts/install.sh       # config, passphrase, cron/systemd, canary
sudo nano /etc/backup-vault/vault.conf
bash vault.sh canary init
sudo bash vault.sh run             # first backup
bash vault.sh drill                # prove it restores
bash vault.sh status               # health report
```

Requirements: Linux with bash 4+, GNU coreutils, openssl, tar, gzip/xz,
rsync (fallback to cp), rclone only for S3 vaults, mysqldump only when
`DB_ENABLED=true`. No root needed for backups themselves, only for the
installer.

## Commands

| Command | What it does |
|---|---|
| `sudo bash vault.sh run` | full backup: canary check, stage, dump, encrypt, ship, rotate |
| `bash vault.sh restore <archive> [dest]` | hash-check, decrypt, extract, verify count |
| `bash vault.sh verify [--remote]` | re-hash every archive against its manifest |
| `bash vault.sh rotate [--dry-run]` | retention promotion + pruning |
| `bash vault.sh drill` | test-restore newest archive, measure RTO |
| `bash vault.sh status` | health audit (exit 60 when unhealthy - cron friendly) |
| `bash vault.sh canary init\|check\|reset` | ransomware tripwire management |

## The 3-2-1 rule, enforced

| Copy | Where | Protected by |
|---|---|---|
| 1 - working data | the server | your hardening (see linux-hardening repo) |
| 2 - local vault | `/var/backup-vault` | AES-256 at rest, sha256 manifests |
| 3 - off-site vault | S3 / SSH vault / NAS | isolated credentials, append-only ingest, optional Object Lock |

## Exit codes

`0` success - `10` config - `20` staging/db - `30` encryption - `40` shipping -
`42` **ransomware tripwire** - `50` verify/restore failure - `60` audit failed.
Monitoring only needs one check: "did it exit 0 today".

## Documentation

- [Architecture](docs/architecture.md) - data flow, storage layout, drivers
- [Threat model](docs/threat-model.md) - ransomware scenarios and controls
- [Disaster recovery runbook](docs/disaster-recovery-runbook.md) - the ransomware day playbook, RPO/RTO, drill procedure

## Part of a security portfolio

This repo is the data-survival layer of a three-project infrastructure
security portfolio:

- [linux-hardening](https://github.com/abdrahmentakrouni/linux-hardening) - one-command server hardening and audit
- [secure-nextcloud](https://github.com/abdrahmentakrouni/secure-nextcloud) - hardened private cloud with TLS, 2FA and RBAC
- **backup-vault** - assume everything else fails: encrypted, tested, off-site recovery

## License

MIT - see [LICENSE](LICENSE).
