# Threat model

## Assets to protect

1. Company data: files, contracts, invoices, databases
2. The backups themselves (they are the survival layer)
3. The backup encryption passphrase (the key to copy 2 and 3)

## Adversaries and hazards

| Hazard | What they want | Consequence |
|---|---|---|
| Ransomware operator | encrypt everything reachable, including backups | total data loss or ransom payment |
| Disgruntled insider | delete backups to cover tracks or hurt the company | unrecoverable loss |
| Thief / cloud breach | steal backup archives | confidential data leak |
| Bit rot / bad disk | - | silent corruption discovered on restore day |
| Human error | - | deleted or overwritten backups, skipped runs nobody noticed |

## Scenarios and controls

### S1 - Ransomware encrypts the server, backups reachable from it

Most "backed up" companies still pay: the malware walks network shares and
credentials until it reaches the backup share and encrypts the copies too.

Controls:
- off-site vault with **separate credentials** (rclone remote, dedicated SSH
  key, separate NAS mount)
- SSH vault runs the **append-only ingest wrapper**: the backup server can
  only `put`, never delete or overwrite - wiping the vault is impossible with
  the stolen key alone
- S3 vaults support **Object Lock (COMPLIANCE mode)**: set
  `PRUNE_REMOTE=false`, no API call can delete inside the retention window
- **canary tripwire**: if decoy files change mid-attack, the next run aborts
  with exit 42 and fires an alert instead of archiving encrypted junk

### S2 - Ransomware encrypts backups by overwriting the backup job output

Control: canary check happens BEFORE staging. A compromised run never writes
into the vault; the last good archive set survives untouched (CI proves this:
after a tripped run, archive count is asserted unchanged).

### S3 - Stolen or leaked backup archive

Control: AES-256-CBC with PBKDF2 (300,000 iterations). Archives are
meaningless without the passphrase. Passphrase handling:
- read from a 0700 directory file or environment, never passed on argv
- installer generates a random 48-character passphrase and instructs printing
  an offline copy
- passphrase recovery is documented as an offline sheet - losing it means
  losing the backups, and that trade-off is stated, not hidden

### S4 - Silent corruption (bit rot, partial disk failure)

Controls:
- every archive has a manifest with SHA-256; `vault.sh verify` re-hashes the
  whole vault (local, and `--remote` for the off-site twin)
- restore always hash-checks the archive BEFORE decrypting, then verifies the
  extracted file count against the manifest

### S5 - The backup job dies and nobody notices for weeks

Controls:
- heartbeat file refreshed after every successful run; any dead-man-switch
  monitor can alert when it goes stale
- webhook events on every failure and tripwire (JSON, one curl away)
- `vault.sh status` measures backup age against the configured RPO and exits
  60 when unhealthy - cron friendly

### S6 - Human error deletes or overwrites backups

Controls:
- GFS retention keeps 7/4/12 generations; yesterday's mistake is one
  `restore` away
- remote pruning is best-effort and can be disabled (`PRUNE_REMOTE=false`)
  for immutable vaults

### S7 - Command injection through backup paths or filenames

Controls:
- remote object names validated against `^[A-Za-z0-9._-]+$` (no traversal, no
  metacharacters) in `remote.sh` and `vault-ingest.sh`
- the SSH ingest wrapper refuses anything but its five verbs; `rm` is not
  implemented, not even by accident
- `MYSQL_PWD` and `VAULT_PW` are passed through the environment, not argv

## Honest limitations

- The local vault on the same disk as the server is copy 2 only: if the disk
  physically dies, only the off-site copy remains - that is why shipping is a
  hard requirement (`exit 40` when it fails)
- AES-256-CBC is not authenticated (no AEAD); the manifest SHA-256 provides
  integrity and tamper detection instead
- A passphrase written on a sticky note next to the server defeats S3; key
  management discipline is out of software's reach - the runbook makes the
  offline sheet a checklist item
- The SSH vault host trusts its own disk; for stronger isolation keep the
  vault host off-domain, firewalled, and accessed only by the backup user
