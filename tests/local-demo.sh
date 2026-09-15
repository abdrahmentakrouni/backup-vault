#!/usr/bin/env bash
# backup-vault - human-friendly demo inside the docker compose stack.
# Runs the core story in about a minute: backup, corrupt data like ransomware,
# restore, prove the recovery. For the full CI-grade drill use
# tests/e2e-disaster-test.sh instead.
set -Eeuo pipefail
ROOT="/opt/backup-vault"
va() { bash "$ROOT/vault.sh" "$@"; }
step() { printf '\n== %s ==\n' "$*"; }

export VAULT_CONFIG="/tmp/vault-demo.conf"
cat > "$VAULT_CONFIG" <<'EOF'
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
BACKUP_PASSPHRASE=demo-passphrase-change-me-0001
CANARY_DIR=/opt/canary
CANARY_BASELINE=/var/lib/backup-vault/canary.sha256
RPO_HOURS=24
EOF
export RCLONE_CONFIG_VAULT_TYPE=s3
export RCLONE_CONFIG_VAULT_ENDPOINT=http://minio:9000
export RCLONE_CONFIG_VAULT_ACCESS_KEY_ID=vaultdemo
export RCLONE_CONFIG_VAULT_SECRET_ACCESS_KEY=vaultdemo-secret
export RCLONE_CONFIG_VAULT_PROVIDER=Minio

step "before: what the company has"
find /srv/data -maxdepth 2 -type f -printf "%10s  %p\n" | head -20
mysql -h db -u backup -pbackupdemo-pass -N -e 'SELECT COUNT(*) FROM appdb.customers'

step "1. nightly backup (files + database, AES-256, off-site to MinIO)"
va canary init >/dev/null
rclone mkdir vault:backups
va run

ARCHIVE="$(find /var/backup-vault/daily -name "*.enc" | sort -r | head -n1)"
step "2. what landed in the vault"
ls -lh /var/backup-vault/daily/
echo "head of the archive file: $(head -c 8 "$ARCHIVE")  <- openssl 'Salted__', not plaintext"

step "3. health audit"
va status || true

step "4. RANSOMWARE: scrambling company files"
for f in /srv/data/finance/*.csv /srv/data/hr/*; do
    [ -f "$f" ] && head -c 1024 /dev/urandom > "$f"
done
echo "finance and hr files are now noise. the database gets dropped too:"
mysql -h db -u root -prootpass-demo-only -e 'DROP DATABASE appdb'

step "5. disaster recovery from the encrypted vault"
RESTORE_DIR="$(mktemp -d /tmp/demo-restore.XXXXXX)"
va restore "$ARCHIVE" "$RESTORE_DIR"
rsync -a "$RESTORE_DIR/files/data/" /srv/data/
zcat "$RESTORE_DIR/db/dump.sql.gz" | mysql -h db -u root -prootpass-demo-only

step "6. after: the company is back"
ls -l /srv/data/finance /srv/data/hr
mysql -h db -u backup -pbackupdemo-pass -N -e 'SELECT COUNT(*) FROM appdb.customers'
echo
echo "DEMO COMPLETE - files restored, database restored, business continuity proven."
echo "Full CI-grade drill: docker compose exec primary bash /opt/backup-vault/tests/e2e-disaster-test.sh"
