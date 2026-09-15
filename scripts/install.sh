#!/usr/bin/env bash
# backup-vault - one-command production installer.
#
#   sudo bash scripts/install.sh
#
# Creates the vault and state directories, writes the configuration, sets up
# cron entries or systemd timers (nightly backup + weekly verification) and
# prints the exact next steps.
set -Eeuo pipefail
LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$LIB_DIR/lib.sh"

[ "$(id -u)" -eq 0 ] || vault_die "$EXIT_CONFIG" "installer must run as root (sudo)"

CONF_DIR="/etc/backup-vault"
CONF_FILE="$CONF_DIR/vault.conf"
BIN_DIR="/usr/local/bin"

install_dirs() {
    mkdir -p "$CONF_DIR" "$STATE_DIR" "$VAULT_DIR/daily" "$VAULT_DIR/weekly" \
             "$VAULT_DIR/monthly" /opt/canary /var/log
    chmod 0700 "$CONF_DIR"
}

install_config() {
    if [ -f "$CONF_FILE" ]; then
        vault_log "config already present: $CONF_FILE (left untouched)"
        return 0
    fi
    if [ -f "$LIB_DIR/../config/vault.conf.example" ]; then
        cp "$LIB_DIR/../config/vault.conf.example" "$CONF_FILE"
    else
        vault_die "$EXIT_CONFIG" "config template missing: config/vault.conf.example"
    fi
    vault_log "configuration written: $CONF_FILE - edit DB_PASSWORD, REMOTE_TYPE and targets now"
}

install_passphrase_file() {
    local pf="$CONF_DIR/passphrase"
    if [ -f "$pf" ]; then
        vault_log "passphrase file already present: $pf (left untouched)"
        return 0
    fi
    vault_log "generating a random 48-character passphrase: $pf"
    local pw
    pw="$(head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 48)"
    umask 077
    printf '%s\n' "$pw" > "$pf"
    umask 022
    vault_log "IMPORTANT: copy this passphrase to your offline recovery sheet now"
    vault_log "(if the server dies AND the passphrase is lost, the backups are gone - print it)"
}

install_bin() {
    if [ -f "$LIB_DIR/../vault.sh" ]; then
        ln -sf "$(cd "$LIB_DIR/.." && pwd)/vault.sh" "$BIN_DIR/backup-vault"
        vault_log "CLI linked: $BIN_DIR/backup-vault"
    fi
}

install_cron() {
    cat > /etc/cron.d/backup-vault <<EOF
# backup-vault schedule (installed by scripts/install.sh)
# nightly backup at 02:00, integrity verification every Sunday 03:30
SHELL=/bin/bash
0 2 * * * root $(command -v bash) $BIN_DIR/backup-vault run >> /var/log/backup-vault.log 2>&1
30 3 * * 0 root $(command -v bash) $BIN_DIR/backup-vault verify --remote >> /var/log/backup-vault-verify.log 2>&1
EOF
    chmod 0644 /etc/cron.d/backup-vault
    vault_log "cron schedule installed: /etc/cron.d/backup-vault (nightly 02:00 + Sunday verify)"
}

install_systemd() {
    cat > /etc/systemd/system/backup-vault.service <<EOF
[Unit]
Description=backup-vault nightly backup
After=network-online.target mariadb.service mysql.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$(command -v bash) $BIN_DIR/backup-vault run
EOF
    cat > /etc/systemd/system/backup-vault-verify.service <<EOF
[Unit]
Description=backup-vault weekly integrity verification
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$(command -v bash) $BIN_DIR/backup-vault verify --remote
EOF
    cat > /etc/systemd/system/backup-vault.timer <<EOF
[Unit]
Description=backup-vault nightly schedule

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
    cat > /etc/systemd/system/backup-vault-verify.timer <<EOF
[Unit]
Description=backup-vault weekly verification schedule

[Timer]
OnCalendar=Sun *-*-* 03:30:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now backup-vault.timer backup-vault-verify.timer
    vault_log "systemd timers installed and enabled (nightly 02:00 + Sunday 03:30)"
}

main() {
    load_config
    install_dirs
    install_config
    install_passphrase_file
    install_bin

    if command -v systemctl >/dev/null 2>&1 && systemctl is-system-running >/dev/null 2>&1; then
        install_systemd
    else
        install_cron
    fi

    printf '\nNext steps:\n'
    printf '  1. edit %s (DB password, off-site target)\n' "$CONF_FILE"
    printf '  2. copy the passphrase to an offline recovery sheet\n'
    printf '  3. plant the canary decoys:   bash %s canary init\n' "$BIN_DIR/backup-vault"
    printf '  4. first backup:              bash %s run\n' "$BIN_DIR/backup-vault"
    printf '  5. prove it restores:         bash %s drill\n' "$BIN_DIR/backup-vault"
    printf '  6. health report:             bash %s status\n' "$BIN_DIR/backup-vault"
}

main "$@"
