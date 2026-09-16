# Architecture

## Data flow

```
                       +-------------------------------------------+
                       |            BACKUP SERVER (primary)        |
                       |                                           |
   cron / systemd ---->  vault.sh run                              |
                       |    |                                      |
                       |    |-- 1. canary check (exit 42 on drift) |
                       |    |                                      |
                       |    |-- 2. stage: rsync SOURCE_DIRS        |
                       |    |        + mysqldump --single-transaction
                       |    |                                      |
   staging (plaintext) |-- 3. tar | gzip | openssl aes-256-cbc     |
   lives only in RAM   |    |        (pbkdf2, 300k iterations)     |
   and tmpfs-ish tmp   |    |                                      |
                       |    |-- 4. manifest (sha256, sizes, params)|
                       |    |                                      |
                       |    |-- 5. ship off-site                   |
                       |    |-- 6. catalog + heartbeat + rotate    |
                       +-------------------------------------------+
                                        |
             +--------------------------+---------------------------+
             |                          |                           |
      REMOTE_TYPE=s3             REMOTE_TYPE=ssh             REMOTE_TYPE=dir
   rclone -> any S3 API       scp/ssh -> vault host        cp -> NAS / USB
   (MinIO, AWS, Wasabi...)    scripts/vault-ingest.sh      (mounted disk)
   optional Object Lock       append-only: put/list/hash   simplest option
                              REFUSES deletes
```

## Vault layout

```
/var/backup-vault/            local vault (copy 2 of 3-2-1)
  daily/    host-stamp.tar.gz.enc   host-stamp.manifest
  weekly/   promotions of Monday archives
  monthly/  promotions of the 1st-of-month archives
  catalog.tsv                 one row per backup: date, class, name, size, sha256

<remote>/                     off-site vault (copy 3 of 3-2-1)
  <host>/daily/...            same tree, namespaced per host
  <host>/weekly/...
  <host>/monthly/...
```

## Archive naming

```
<host>-<UTC stamp>.tar.gz.enc          e.g. web01-20260916T020012Z.tar.gz.enc
<host>-<UTC stamp>.tar.gz.manifest     sha256, format, iterations, file count
```

The stamp is UTC. Names sort chronologically, which makes retention and
"newest backup" checks deterministic without touching mtimes.

## Manifest format

Flat `key=value` lines, versioned with `manifest-version=1`, greppable with
standard tools:

```
manifest-version=1
host=web01
created=2026-09-16T02:00:12+0100
class=daily
archive=web01-20260916T020012Z.tar.gz.enc
format=tar.gz
encryption=aes-256-cbc
kdf=pbkdf2
iterations=300000
size-bytes=18432
sha256=<hex>
files=57
bytes-uncompressed=233472
databases=appdb
source-dirs=/srv/data
```

## Components

| File | Role |
|---|---|
| `vault.sh` | CLI dispatcher (run, restore, verify, rotate, drill, status, canary, install) |
| `scripts/backup-engine.sh` | the pipeline: canary -> stage -> dump -> encrypt -> ship -> catalog -> rotate |
| `scripts/remote.sh` | off-site drivers: s3 (rclone), ssh (append-only), dir |
| `scripts/canary.sh` | ransomware tripwire: decoys + baseline + check |
| `scripts/rotate.sh` | GFS promotion + pruning, local and remote |
| `scripts/restore.sh` | hash check -> decrypt -> extract -> count verify (+ `--test` drill) |
| `scripts/verify.sh` | re-hash every archive, optional remote verification |
| `scripts/audit.sh` | health report: RPO age, encryption, off-site, schedule, drill, disk |
| `scripts/notify.sh` | webhook events + heartbeat file |
| `scripts/install.sh` | production installer (config, passphrase, cron/systemd) |
| `scripts/vault-ingest.sh` | server-side append-only ingest for the SSH vault host |
| `scripts/lib.sh` | shared helpers, config loading, exit codes |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | success |
| 10 | configuration error (missing tool, bad passphrase, unknown driver) |
| 20 | staging or database dump failure |
| 30 | encryption failure |
| 40 | off-site shipping failure (local copy still kept) |
| 42 | ransomware canary tripwire - backup deliberately aborted |
| 50 | verify or restore failure |
| 60 | health audit failed (usable as cron alert signal) |

## Failure handling

| Failure | Behaviour |
|---|---|
| canary drift | run aborts before staging anything; webhook fires; exit 42 |
| mysqldump missing/fails | hard fail (exit 20): a file-only backup of a DB server is a time bomb |
| off-site push fails | local archive is kept, failure is loud (webhook + exit 40) |
| rotation errors | logged and alerted, never blocks the backup itself |
| restore on corrupted archive | sha256 checked BEFORE decryption; corrupt copies are refused (pull the off-site twin instead) |
