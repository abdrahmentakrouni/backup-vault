#!/usr/bin/env bash
# backup-vault - main command line interface.
#
#   bash vault.sh <command>
#
#   run                     take a backup (canary check, stage, dump, encrypt, ship, rotate)
#   restore <arc> [dest]    restore an archive ("latest" picks the newest)
#   verify [--remote]       integrity-check every archive against its manifest
#   rotate [--dry-run]      retention promotion + pruning (7 daily / 4 weekly / 12 monthly)
#   drill                   disaster drill: test-restore the newest archive, measure RTO
#   status                  backup health audit (RPO age, encryption, off-site, schedule...)
#   canary init|check|reset ransomware tripwire management
#   install                 production installer (cron/systemd, config, passphrase)
#   version                 print version
#
# Run everything through bash (no executable bit needed):
#   sudo bash vault.sh run
set -Eeuo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)/scripts"

usage() {
    sed -n '/^#   run/,/^#   version/p' "$0" | sed 's/^# \{0,3\}//'
}

case "${1:-}" in
    run)     shift; exec bash "$DIR/backup-engine.sh" "$@" ;;
    restore) shift; exec bash "$DIR/restore.sh" "$@" ;;
    verify)  shift; exec bash "$DIR/verify.sh" "$@" ;;
    rotate)  shift; exec bash "$DIR/rotate.sh" "$@" ;;
    status|audit) shift; exec bash "$DIR/audit.sh" "$@" ;;
    drill)   shift; exec bash "$DIR/restore.sh" latest --test ;;
    canary)
        sub="${2:-check}"
        shift 2 || true
        exec bash "$DIR/canary.sh" "$sub"
        ;;
    install) shift; exec bash "$DIR/install.sh" "$@" ;;
    version) printf 'backup-vault %s\n' "1.0.0" ;;
    ""|-h|--help|help) usage ;;
    *)
        printf 'unknown command: %s\n\n' "$1" >&2
        usage >&2
        exit 10
        ;;
esac
