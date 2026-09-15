#!/usr/bin/env bash
# backup-vault - ransomware canary tripwire.
#
# Decoy "business" files are planted where attackers look first. Their hashes
# form a baseline; every backup run re-checks them. If a decoy changed, the
# chances are high that ransomware is busy encrypting the server RIGHT NOW -
# so the run aborts (exit 42) instead of archiving encrypted junk over the
# last good backups and pushing it off-site.
set -Eeuo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/lib.sh"

canary_marker() {
    cat <<'EOF'
BACKUP-VAULT CANARY FILE
This decoy is watched by the backup system. If you are reading this while
investigating an incident, the tripwire did its job: the vault should still
hold clean, restorable backups taken before the compromise.
EOF
}

canary_init() {
    mkdir -p "$CANARY_DIR"
    local f
    # Names chosen to be first in line when ransomware sorts by "value".
    for f in invoice-2026-09.docx customer-database.xlsx contracts-master.xlsx \
             payroll-export.csv accounting-ledger.docx; do
        { canary_marker; printf 'decoy: %s\nhost: %s\n' "$f" "$HOSTNAME_TAG"; } \
            > "$CANARY_DIR/$f"
    done
    canary_reset
    vault_log "canary decoys planted in $CANARY_DIR (baseline: $CANARY_BASELINE)"
}

canary_reset() {
    mkdir -p "$(dirname "$CANARY_BASELINE")"
    ( cd "$CANARY_DIR" && sha256sum invoice-2026-09.docx customer-database.xlsx \
        contracts-master.xlsx payroll-export.csv accounting-ledger.docx \
        > "$CANARY_BASELINE" )
    chmod 0600 "$CANARY_BASELINE"
    vault_log "canary baseline refreshed: $CANARY_BASELINE"
}

canary_check() {
    if [ ! -f "$CANARY_BASELINE" ]; then
        vault_warn "canary tripwire not initialized - run: bash vault.sh canary init"
        return 0
    fi
    if [ ! -d "$CANARY_DIR" ]; then
        vault_log "TRIPWIRE: canary directory vanished: $CANARY_DIR"
        return 42
    fi
    if ( cd "$CANARY_DIR" && sha256sum -c "$CANARY_BASELINE" --quiet >/dev/null 2>&1 ); then
        vault_log "canary check: decoys intact"
        return 0
    fi
    vault_log "TRIPWIRE: canary files changed - suspected ransomware activity on $HOSTNAME_TAG"
    return 42
}

case "${1:-}" in
    init)  load_config; canary_init ;;
    reset) load_config; canary_reset ;;
    check) load_config; canary_check ;;
    *)     vault_die "$EXIT_CONFIG" "usage: canary.sh init | check | reset" ;;
esac
