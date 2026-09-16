# Disaster recovery runbook

This is the document you do not want to read for the first time during an
incident. Print it, drill it monthly, keep a copy outside the primary server.

## Objectives

| Metric | Target | Measured by |
|---|---|---|
| RPO (max data loss window) | 24 h (nightly schedule) | `vault.sh status` backup-age check |
| RTO (max restore duration) | < 30 min for this class of server | `vault.sh drill` (prints measured seconds) |

## Prerequisites (keep offline)

- [ ] `BACKUP_PASSPHRASE` printed on paper, stored in a safe (TWO copies, two places)
- [ ] vault host address / rclone remote name
- [ ] this runbook, current version
- [ ] a second Linux machine able to run the restore (any VM works)

## Incident levels

| Level | Trigger | Action |
|---|---|---|
| L1 | single file deleted / bad deploy | `vault.sh restore <archive>` (section A) |
| L2 | database corruption | file + DB restore (section A, step 5) |
| L3 | ransomware detected | full playbook (section B) |
| L4 | server hardware dead | rebuild + restore on new machine (section C) |

## Section A - standard restore

```bash
# 1. list what exists
ls -lh /var/backup-vault/daily/

# 2. dry check: hash + decrypt + extract + verify
sudo bash vault.sh restore latest /tmp/restore-check

# 3. restore files where they belong (staging tree mirrors SOURCE_DIRS)
rsync -a /tmp/restore-check/files/<source-name>/ /srv/data/

# 4. restore databases
zcat /tmp/restore-check/db/dump.sql.gz | mysql -h 127.0.0.1 -u root -p

# 5. verify
sudo bash vault.sh verify --remote
sudo bash vault.sh status
```

## Section B - ransomware playbook

1. **Isolate** - unplug the server (network, not power). Stop backup cron
   temporarily: `sudo systemctl stop backup-vault.timer` (or move
   `/etc/cron.d/backup-vault` aside). A compromised machine must not touch the
   vault again.
2. **Assess** - is the tripwire tripped? `bash vault.sh canary check`.
   Check the vault: `sudo bash vault.sh verify` - every FAIL is an archive to
   discard; restore only PASSing archives, prefer the off-site twin.
3. **Preserve evidence** - one scrambled sample file + the tripwire log line
   + `last -20` output. Then stop investigating: recovery first.
4. **Rebuild clean** - reinstall the OS (do not trust a decrypted ransomware
   host), re-harden (linux-hardening), restore data only.
5. **Restore** - section A on the new machine, pulling from the off-site
   vault when the local vault is suspect:
   `bash scripts/remote.sh pull` equivalent: mount the dir vault or reconfigure
   `REMOTE_TYPE`, then `sudo bash vault.sh restore <archive>`.
6. **Verify business data** - row counts, newest invoice date, application
   login, checksums: `find /srv/data -type f | sort | xargs sha256sum`.
7. **Re-arm** - `bash vault.sh canary reset`, restart schedules, run
   `sudo bash vault.sh run`, then `bash vault.sh drill`.
8. **Report** - update RPO/RTO actuals in this runbook with what really
   happened (times, what failed, what you wished existed).

## Section C - new machine, vault is all that is left

```bash
git clone https://github.com/abdrahmentakrouni/backup-vault.git
cd backup-vault
sudo bash scripts/install.sh
sudo nano /etc/backup-vault/vault.conf   # point REMOTE_TYPE at the vault
sudo bash vault.sh restore <archive-name> /srv/restore
# then rebuild the local vault from the off-site copy and continue nightly runs
```

## Monthly drill (calendar item, 15 minutes)

```bash
bash vault.sh drill          # test-restores newest archive, measures RTO
sudo bash vault.sh verify --remote
sudo bash vault.sh status
```

Acceptance: drill PASSED, audit PASS, drill age < 35 days in the status
report. If any of that is red, fixing the backup system outranks every other
infrastructure task that week.

## Contact template

| Role | Name | Channel |
|---|---|---|
| Incident lead | _fill in_ | _fill in_ |
| Backup owner | _fill in_ | _fill in_ |
| Management decision (ransom) | _fill in_ | _fill in_ |

Decision to pre-make with management: the company does not negotiate with
ransomware; the vault is the negotiation. Saying this out loud once, calmly,
in a meeting is cheaper than deciding it live at 3 a.m.
