#!/usr/bin/env bash
# backup-vault - local functional smoke test (no docker, no network).
# Drives the real engine with a directory vault and a fake "source server":
#   backup -> encryption check -> tripwire -> rotation -> restore -> verify -> audit
# Used by CI's static job and by anyone wanting a 30-second sanity check.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0

step() { printf '\n== %s ==\n' "$*"; }
ok()   { printf '   PASS: %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf '   FAIL: %s\n' "$*"; exit 1; }

T="$(mktemp -d /tmp/vault-smoke.XXXXXX)"
trap 'rm -rf "$T"' EXIT

# Fake company server
SRC="$T/srv/data"
mkdir -p "$SRC/finance" "$SRC/db-export"
printf 'invoice,total\n1,900\n2,149\n' > "$SRC/finance/invoices.csv"
printf 'contract %s\n' "$(seq 1 40)" > "$SRC/finance/contracts.txt"
head -c 50000 /dev/urandom | base64 > "$SRC/db-export/blob.txt"

export VAULT_CONFIG="$T/vault.conf"
cat > "$VAULT_CONFIG" <<EOF
VAULT_DIR="$T/vault"
STATE_DIR="$T/state"
SOURCE_DIRS="$SRC"
REMOTE_TYPE="dir"
DIR_TARGET="$T/offsite"
DB_ENABLED=false
BACKUP_PASSPHRASE="smoke-test-passphrase-0123456789"
CANARY_DIR="$T/canary"
CANARY_BASELINE="$T/state/canary.sha256"
RPO_HOURS=24
EOF

export VA="bash $ROOT/vault.sh"

step "backup run"
$VA canary init >/dev/null
$VA run > "$T/run.log" 2>&1 || fail "vault.sh run exited nonzero: $(tail -3 "$T/run.log")"
ARCHIVE="$(find "$T/vault/daily" -name "*.enc" | sort | head -n 1)"
[ -n "$ARCHIVE" ] || fail "no archive in the vault"
ok "archive created: $(basename "$ARCHIVE")"

step "encryption at rest"
[ "$(head -c 8 "$ARCHIVE")" = "Salted__" ] || fail "archive is not openssl-encrypted"
ok "openssl salted header present"
grep -q 'encryption=aes-256-cbc' "${ARCHIVE%.enc}.manifest" || fail "manifest missing encryption params"
ok "manifest records aes-256-cbc + pbkdf2"

step "off-site copy (dir driver)"
[ -f "$T/offsite/$(hostname -s)/daily/$(basename "$ARCHIVE")" ] || fail "archive not shipped off-site"
ok "off-site copy present"

step "integrity manifest"
sha="$(grep '^sha256=' "${ARCHIVE%.enc}.manifest" | cut -d= -f2-)"
[ "$sha" = "$(sha256sum "$ARCHIVE" | cut -d' ' -f1)" ] || fail "manifest sha256 mismatch"
ok "sha256 matches"

step "ransomware canary tripwire"
printf 'tampered' >> "$T/canary/invoice-2026-09.docx"
code=0
$VA run >/dev/null 2>&1 || code=$?
[ "$code" -eq 42 ] || fail "expected exit 42, got $code"
ok "backup aborted with exit code 42 (vault untouched)"
$VA canary reset >/dev/null
ok "tripwire reset (post-incident procedure)"

step "retention rotation"
for i in 1 2 3 4 5 6 7 8 9 10; do
    OLD="$(date -u -d "-${i} days" '+%Y%m%dT%H%M%SZ' 2>/dev/null || date -u -v-${i}d '+%Y%m%dT%H%M%SZ')"
    NEWNAME="$(basename "$ARCHIVE" | sed "s/[0-9]\{8\}T[0-9]\{6\}Z/$OLD/")"
    cp "$ARCHIVE" "$T/vault/daily/$NEWNAME"
    cp "${ARCHIVE%.enc}.manifest" "$T/vault/daily/${NEWNAME%.enc}.manifest"
done
$VA rotate > "$T/rotate.log" 2>&1
COUNT="$(find "$T/vault/daily" -name "*.enc" | wc -l)"
[ "$COUNT" -le 7 ] || fail "retention kept $COUNT dailies (limit 7)"
ok "pruned to $COUNT daily archives (limit 7)"

step "restore and byte-for-byte comparison"
DEST="$T/restored"
$VA restore "$ARCHIVE" "$DEST" > "$T/restore.log" 2>&1 || fail "restore failed: $(tail -3 "$T/restore.log")"
SUB="$(find "$DEST/files" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
diff -r "$SUB" "$SRC" > /dev/null 2>&1 || fail "restored files differ from source"
ok "restored tree is byte-identical to the original"

step "verify + audit"
$VA verify > "$T/verify.log" 2>&1 || fail "verify failed"
ok "vault verification passed"
$VA status > "$T/audit.log" 2>&1 || fail "audit failed: $(cat "$T/audit.log")"
ok "health audit passed"

printf '\nSMOKE TEST PASSED (%d checks)\n' "$PASS"
