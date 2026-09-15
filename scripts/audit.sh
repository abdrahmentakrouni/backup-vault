#!/usr/bin/env bash
# backup-vault - backup health audit (also the "status" command).
#
# Checks: backup age vs RPO, encryption, off-site copy, canary, schedule,
# last drill, vault disk pressure, catalog consistency. Exit 0 = healthy,
# 60 = at least one check FAILED (warnings alone do not fail the audit).
set -Eeuo pipefail
LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$LIB_DIR/lib.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/remote.sh"

PASS=0
WARN=0
FAIL=0

report() {
    local state="$1" name="$2" detail="$3"
    printf '[%-4s] %-22s %s\n' "$state" "$name" "$detail"
    case "$state" in
        PASS) PASS=$((PASS + 1)) ;;
        WARN) WARN=$((WARN + 1)) ;;
        FAIL) FAIL=$((FAIL + 1)) ;;
    esac
}

age_hours() {  # age_hours <file> -> hours since mtime (or empty)
    local f="$1"
    [ -f "$f" ] || { printf ''; return 0; }
    local mtime now
    mtime="$(stat -c '%Y' "$f")"
    now="$(date +%s)"
    printf '%s' "$(( (now - mtime) / 3600 ))"
}

newest_archive() {
    # newest by stamp (archive names sort chronologically within a host)
    local c name
    for c in daily weekly monthly; do
        name="$(list_enc "$c" | sort -r | head -n 1)"
        [ -n "$name" ] && { printf '%s/%s' "$c" "$name"; return 0; }
    done
    return 0
}

list_enc() {
    local f
    for f in "$VAULT_DIR/$1"/*.enc; do
        [ -e "$f" ] || continue
        printf '%s\n' "$(basename "$f")"
    done
}

main() {
    load_config
    require_driver_config
    ensure_dirs

    printf 'backup-vault audit - %s (%s)\n\n' "$HOSTNAME_TAG" "$(date '+%Y-%m-%d %H:%M %Z')"

    # 1. Backup age vs RPO
    local newest rel hours
    newest="$(newest_archive)"
    if [ -n "$newest" ]; then
        rel="$newest"
        hours="$(age_hours "$VAULT_DIR/$newest")"
        if [ "${hours:-999999}" -le "$RPO_HOURS" ]; then
            report PASS "backup age" "last backup ${hours}h ago (RPO ${RPO_HOURS}h): $rel"
        elif [ "${hours:-999999}" -le $((RPO_HOURS * 2)) ]; then
            report WARN "backup age" "last backup ${hours}h ago exceeds RPO ${RPO_HOURS}h: $rel"
        else
            report FAIL "backup age" "last backup ${hours}h ago - RPO ${RPO_HOURS}h breached, data at risk"
        fi
    else
        report FAIL "backup age" "vault has no archives at all"
    fi

    # 2. Encryption spot check (openssl salted header + manifest params)
    if [ -n "$newest" ]; then
        local head8 enc kdf
        head8="$(head -c 8 "$VAULT_DIR/$newest")"
        enc="$(manifest_get encryption "$VAULT_DIR/${newest%.enc}.manifest" 2>/dev/null || true)"
        kdf="$(manifest_get kdf "$VAULT_DIR/${newest%.enc}.manifest" 2>/dev/null || true)"
        if [ "$head8" = "Salted__" ] && [ "$enc" = "aes-256-cbc" ] && [ "$kdf" = "pbkdf2" ]; then
            report PASS "encryption" "newest archive is AES-256 encrypted ($kdf)"
        else
            report FAIL "encryption" "newest archive fails the encryption spot check"
        fi
    fi

    # 3. Off-site copy of the newest archive
    if [ -n "$newest" ]; then
        local cls nm mf_name
        cls="${newest%%/*}"
        nm="${newest#*/}"
        mf_name="${nm%.enc}.manifest"
        if remote_exists "$cls" "$nm" && remote_exists "$cls" "$mf_name"; then
            report PASS "off-site copy" "newest archive + manifest present on $REMOTE_TYPE vault"
        else
            report FAIL "off-site copy" "newest archive missing off-site - 3-2-1 rule broken"
        fi
    fi

    # 4. Canary tripwire
    if [ -f "$CANARY_BASELINE" ]; then
        if bash "$LIB_DIR/canary.sh" check >/dev/null 2>&1; then
            report PASS "canary tripwire" "decoys intact (baseline $CANARY_BASELINE)"
        else
            report FAIL "canary tripwire" "decoys changed - investigate for ransomware activity"
        fi
    else
        report WARN "canary tripwire" "not initialized - run: bash vault.sh canary init"
    fi

    # 5. Schedule installed?
    if [ -f /etc/cron.d/backup-vault ] || \
       systemctl list-timers --all 2>/dev/null | grep -q backup-vault || \
       [ -f /etc/systemd/system/backup-vault.timer ]; then
        report PASS "schedule" "backup scheduled (cron or systemd timer)"
    else
        report WARN "schedule" "no cron/timer found - backups are manual only - run: bash vault.sh install"
    fi

    # 6. Last disaster drill
    local drill_age
    drill_age="$(age_hours "$STATE_DIR/last-drill")"
    if [ -z "$drill_age" ]; then
        report WARN "restore drill" "never drilled - a backup is only a backup after a successful restore test"
    elif [ "$drill_age" -le 720 ]; then
        report PASS "restore drill" "last drill ${drill_age}h ago ($(( drill_age / 24 )) days)"
    else
        report WARN "restore drill" "last drill ${drill_age}h ago - schedule a monthly drill"
    fi

    # 7. Vault disk pressure
    local use
    use="$(df -P "$VAULT_DIR" | awk 'NR==2 {gsub(/%/, "", $5); print $5}')"
    if [ "${use:-0}" -lt 80 ]; then
        report PASS "vault disk" "filesystem ${use}% used"
    elif [ "${use:-0}" -lt 90 ]; then
        report WARN "vault disk" "filesystem ${use}% used - plan capacity"
    else
        report FAIL "vault disk" "filesystem ${use}% used - retention will soon fail to write"
    fi

    # 8. Catalog consistency
    local archives catalogs
    archives="$(find "$VAULT_DIR"/daily "$VAULT_DIR"/weekly "$VAULT_DIR"/monthly \
                    -name '*.enc' 2>/dev/null | wc -l)"
    catalogs=0
    [ -f "$VAULT_DIR/catalog.tsv" ] && catalogs="$(wc -l < "$VAULT_DIR/catalog.tsv")"
    if [ "$catalogs" -ge "$archives" ]; then
        report PASS "catalog" "$archives archives, $catalogs catalog rows"
    else
        report WARN "catalog" "$archives archives vs $catalogs catalog rows - some backups predate the catalog"
    fi

    printf '\n'
    if [ "$FAIL" -gt 0 ]; then
        printf 'AUDIT RESULT: FAIL (%d passed, %d warnings, %d failed)\n' "$PASS" "$WARN" "$FAIL"
        exit "$EXIT_AUDIT"
    fi
    printf 'AUDIT RESULT: PASS (%d passed, %d warnings, 0 failed)\n' "$PASS" "$WARN"
    exit "$EXIT_OK"
}

main "$@"
