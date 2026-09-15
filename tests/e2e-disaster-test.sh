#!/usr/bin/env bash
# backup-vault - end-to-end disaster recovery simulation (CI + demo).
#
# Runs INSIDE the "primary" container of the docker compose stack:
#
#   1. baseline hash of the company files + database
#   2. real backup: stage + mysqldump + AES-256 encrypt + ship to MinIO (S3)
#   3. prove the archive: manifest hash, openssl header, DB dump inside
#   4. retention rotation with forged old archives (GFS 7/4/12)
#   5. ransomware canary tripwire: tamper -> expect exit 42 -> reset
#   6. RANSOMWARE: scramble every company file AND drop the database
#   7. DR: restore files + database from the encrypted vault
#   8. prove the recovery: byte-for-byte hash comparison, row-level DB check
#   9. verify + drill + health audit
#
# Every step is fatal on failure: if any assertion breaks, CI goes red.
set -Eeuo pipefail
ROOT="/opt/backup-vault"
PASS=0

step() { printf '\n== %s ==\n' "$*"; }
ok()   { printf '   PASS: %s\n' "$*"; PASS=$((PASS + 1)); }
va()   { bash "$ROOT/vault.sh" "$@"; }
mysqlq() { MYSQL_PWD=backupdemo-pass mysql -h db -u backup -N "$@"; }
mysqlrootq() { MYSQL_PWD=rootpass-demo-only mysql -h db -u root -N "$@"; }

fail_hard() {
    printf '\n!! SIMULATION FAILED: %s\n' "$*" >&2
    exit 1
}

# ---------------------------------------------------------------- config ----
export VAULT_CONFIG="/tmp/vault-ci.conf"
cat > "$VAULT_CONFIG" <<EOF
VAULT_DIR=/var/backup-vault
STATE_DIR=/var/lib/backup-vault
SOURCE_DIRS=/srv/data
DB_ENABLED=true
DB_HOST=db
DB_PORT=3306
DB_USER=backup
DB_PASSWORD=backupdemo-pass
DB_NAMES=appdb
REMOTE_TYPE=s3
RCLONE_TARGET=vault:backups
PRUNE_REMOTE=true
BACKUP_PASSPHRASE=e2e-disaster-drill-passphrase-9876543210
CANARY_DIR=/opt/canary
CANARY_BASELINE=/var/lib/backup-vault/canary.sha256
RPO_HOURS=24
EOF
export RCLONE_CONFIG_VAULT_TYPE=s3
export RCLONE_CONFIG_VAULT_ENDPOINT=http://minio:9000
export RCLONE_CONFIG_VAULT_ACCESS_KEY_ID=vaultdemo
export RCLONE_CONFIG_VAULT_SECRET_ACCESS_KEY=vaultdemo-secret
export RCLONE_CONFIG_VAULT_PROVIDER=Minio

VAULT_PW=e2e-disaster-drill-passphrase-9876543210
export VAULT_PW

# ------------------------------------------------------------- 1. baseline --
step "1. baseline: company files and database"
mkdir -p /srv/data
find /srv/data -type f | sort | xargs sha256sum > /tmp/baseline.sha
[ "$(wc -l < /tmp/baseline.sha)" -ge 3 ] || fail_hard "expected sample files in /srv/data"
[ "$(mysqlq -e 'SELECT COUNT(*) FROM appdb.customers')" = "4" ] \
    || fail_hard "seed data missing"
ok "$(wc -l < /tmp/baseline.sha) files hashed, database reachable (4 customers)"

# ----------------------------------------------------------- 2. the backup --
step "2. backup run (canary -> stage -> mysqldump -> AES-256 -> S3)"
va canary init >/dev/null
rclone mkdir vault:backups
va run > /tmp/backup.log 2>&1 || fail_hard "vault.sh run failed: $(tail -5 /tmp/backup.log)"
grep -q "database dump complete: appdb" /tmp/backup.log || fail_hard "no database dump in backup log"
ARCHIVE="$(find /var/backup-vault/daily -name "*.enc" | sort -r | head -n1)"
MANIFEST="${ARCHIVE%.enc}.manifest"
[ -f "$ARCHIVE" ] || fail_hard "no archive in local vault"
ok "archive sealed: $(basename "$ARCHIVE") ($(du -h "$ARCHIVE" | cut -f 1))"

# ------------------------------------------------ 3. prove the archive ------
step "3. proof: manifest hash, encryption header, off-site copy, DB inside"
[ "$(grep '^sha256=' "$MANIFEST" | cut -d= -f2-)" = "$(sha256sum "$ARCHIVE" | cut -d' ' -f1)" ] \
    || fail_hard "manifest sha256 mismatch"
ok "manifest sha256 matches"
[ "$(head -c 8 "$ARCHIVE")" = "Salted__" ] || fail_hard "archive is not openssl-encrypted"
ok "openssl salted header present (aes-256-cbc, pbkdf2 x300000)"
rclone lsf "vault:backups/$(hostname -s)/daily/$(basename "$ARCHIVE")" >/dev/null 2>&1 \
    || fail_hard "archive missing on the S3 vault"
ok "off-site copy verified on MinIO (s3 driver)"
rclone lsf "vault:backups/$(hostname -s)/daily/$(basename "$MANIFEST")" >/dev/null 2>&1 \
    || fail_hard "manifest missing on the S3 vault"
ok "manifest shipped off-site too"

openssl enc -d -aes-256-cbc -pbkdf2 -iter 300000 -salt -pass env:VAULT_PW \
    -in "$ARCHIVE" | tar -tz | grep -q 'db/dump.sql.gz' || fail_hard "database dump not inside the archive"
ok "database dump confirmed inside the encrypted archive"

# -------------------------------------------------------- 4. retention ------
step "4. retention rotation (GFS 7 daily / 4 weekly / 12 monthly)"
for i in 1 2 3 4 5 6 7 8 9 10; do
    OLD="$(date -u -d "-${i} days" '+%Y%m%dT%H%M%SZ')"
    NEWNAME="$(basename "$ARCHIVE" | sed "s/[0-9]\{8\}T[0-9]\{6\}Z/$OLD/")"
    cp "$ARCHIVE" "/var/backup-vault/daily/$NEWNAME"
    cp "$MANIFEST" "/var/backup-vault/daily/${NEWNAME%.enc}.manifest"
done
va rotate > /tmp/rotate.log 2>&1 || fail_hard "rotate failed: $(tail -3 /tmp/rotate.log)"
COUNT="$(find /var/backup-vault/daily -name "*.enc" | wc -l)"
[ "$COUNT" -le 7 ] || fail_hard "retention kept $COUNT dailies (limit 7)"
ok "pruned to $COUNT daily archives (limit 7)"

# --------------------------------------------------------- 5. tripwire ------
step "5. ransomware canary tripwire"
printf 'tampered' >> /opt/canary/invoice-2026-09.docx
CODE=0
va run >/dev/null 2>&1 || CODE=$?
[ "$CODE" -eq 42 ] || fail_hard "tripwire expected exit 42, got $CODE"
COUNT2="$(find /var/backup-vault/daily -name "*.enc" | wc -l)"
[ "$COUNT2" = "$COUNT" ] || fail_hard "a failed run must not touch the vault"
ok "tampered decoy -> backup aborted (exit 42), vault untouched"
va canary reset >/dev/null
ok "tripwire reset"

# --------------------------------------------- 6. the ransomware incident ---
step "6. RANSOMWARE SIMULATION: encrypting the company server"
find /srv/data -type f | while IFS= read -r f; do
    head -c 2048 /dev/urandom > "$f"
done
find /srv/data -type f | sort | xargs sha256sum > /tmp/ransomware.sha
if diff -q /tmp/baseline.sha /tmp/ransomware.sha >/dev/null 2>&1; then
    fail_hard "ransomware simulation changed nothing (test setup broken)"
fi
ok "$(wc -l < /tmp/ransomware.sha) files scrambled with random bytes"
mysqlrootq -e 'DROP DATABASE appdb; CREATE DATABASE appdb;'
if mysqlq -e 'SELECT COUNT(*) FROM appdb.customers' >/dev/null 2>&1; then
    fail_hard "database should be gone"
fi
ok "database appdb dropped (ransomware wiped it)"

# ---------------------------------------------------------- 7. recovery -----
step "7. disaster recovery: restore from the encrypted vault"
RESTORE_DIR="$(mktemp -d /tmp/dr.XXXXXX)"
va restore "$ARCHIVE" "$RESTORE_DIR" > /tmp/restore.log 2>&1 \
    || fail_hard "restore failed: $(tail -5 /tmp/restore.log)"
ok "archive decrypted and extracted"

rsync -a "$RESTORE_DIR/files/data/" /srv/data/
find /srv/data -type f | sort | xargs sha256sum > /tmp/restored.sha
if ! diff -q /tmp/baseline.sha /tmp/restored.sha >/dev/null 2>&1; then
    fail_hard "restored files do not match the pre-incident baseline"
fi
ok "files recovered byte-for-byte ($(wc -l < /tmp/restored.sha) files match)"
zcat "$RESTORE_DIR/db/dump.sql.gz" | mysqlrootq >/dev/null 2>&1 \
    || fail_hard "database replay failed"
ok "database replayed from the encrypted dump"
[ "$(mysqlq -e 'SELECT COUNT(*) FROM appdb.customers')" = "4" ] \
    || fail_hard "customer table did not recover (expected 4 rows)"
mysqlq -e "SELECT name FROM appdb.customers WHERE name='ACME Industries'" | grep -q ACME \
    || fail_hard "row-level check failed: ACME Industries missing"
ok "row-level check: 4 customers back, ACME Industries present"

# ------------------------------------------------ 8. verify + drill + audit -
step "8. verification, drill and health audit"
va verify > /tmp/verify.log 2>&1 || fail_hard "verify failed"
ok "every archive matches its manifest"
va drill > /tmp/drill.log 2>&1 || fail_hard "drill failed: $(tail -3 /tmp/drill.log)"
RTO="$(cat /var/lib/backup-vault/last-drill-seconds)"
ok "scheduled drill passed (RTO ${RTO}s)"
va status > /tmp/audit.log 2>&1 || fail_hard "audit failed: $(cat /tmp/audit.log)"
ok "health audit: PASS"

printf '\n=============================================\n'
printf '  DISASTER RECOVERY SIMULATION PASSED\n'
printf '  backups: %d checks | RTO measured: %ss | RPO: 24h\n' "$PASS" "$RTO"
printf '  the company survives ransomware. business continuity: proven.\n'
printf '=============================================\n'
