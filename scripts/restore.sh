#!/usr/bin/env bash
# backup-vault - restore: hash check first, decrypt, extract, count-verify.
#
#   restore.sh <archive.enc> [dest] [--diff SOURCE_DIR] [--test]
#
# --diff compares the restored copy against a live source directory.
# --test restores the newest archive into a temp dir (disaster drill) and
# records the measured RTO in $STATE_DIR/last-drill.
set -Eeuo pipefail
LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$LIB_DIR/lib.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/remote.sh"

usage() {
    cat <<'EOF'
usage: bash scripts/restore.sh <archive.enc> [dest] [--diff SRC] [--test]

  archive.enc   path inside the vault (daily/weekly/monthly), newest is
                auto-selected when the argument is "latest"
  dest          extraction directory (default: ./restored-<stamp>)
  --diff SRC    after extraction, compare restored files with SRC (exit 50 on drift)
  --test        disaster drill: extract newest archive to a temp dir, measure RTO
EOF
}

decompress_flag() {
    case "$1" in
        tar.gz)  printf -- '-z' ;;
        tar.xz)  printf -- '-J' ;;
        tar)     printf '' ;;
        *) vault_die "$EXIT_VERIFY" "unknown archive format in manifest: $1" ;;
    esac
}

restore_archive() {
    # restore_archive <archive> <dest>
    local archive="$1" dest="$2" mf format sha sha_now iter flag
    mf="${archive%.enc}.manifest"

    if [ ! -f "$archive" ]; then
        vault_die "$EXIT_VERIFY" "archive not found: $archive"
    fi
    if [ -f "$mf" ]; then
        format="$(manifest_get format "$mf")"
        sha="$(manifest_get sha256 "$mf")"
        iter="$(manifest_get iterations "$mf")"
        sha_now="$(sha256sum "$archive" | cut -d ' ' -f 1)"
        [ "$sha_now" = "$sha" ] || vault_die "$EXIT_VERIFY" \
            "integrity check FAILED: $archive does not match its manifest sha256 - do not trust this copy, pull from the off-site vault"
        vault_log "integrity check passed (sha256 matches manifest)"
    else
        vault_warn "no manifest next to $archive - proceeding without a reference hash"
        format="$(compression_ext)"
    fi
    [ -n "$format" ] || format="$(compression_ext)"

    export_openssl_passphrase
    flag="$(decompress_flag "$format")"
    mkdir -p "$dest"
    # shellcheck disable=SC2086
    openssl enc -d -aes-256-cbc -pbkdf2 -iter "${iter:-$ENCRYPT_ITERATIONS}" \
        -salt -pass env:VAULT_PW -in "$archive" | tar -xf - $flag -C "$dest"

    if [ -f "$mf" ]; then
        local expected got
        expected="$(manifest_get files "$mf")"
        got="$(find "$dest" -type f | wc -l)"
        if [ "$got" -lt "$expected" ]; then
            vault_die "$EXIT_VERIFY" \
                "restore incomplete: $got of $expected files extracted"
        fi
        vault_log "file count verified: $got/$expected"
    fi
}

list_enc_names() {
    local f
    for f in "$1"/*.enc; do
        [ -e "$f" ] || continue
        printf '%s\n' "$(basename "$f")"
    done
}

pick_latest() {
    # newest archive across classes (daily first, then weekly, then monthly)
    local c f
    for c in daily weekly monthly; do
        f="$(list_enc_names "$VAULT_DIR/$c" | sort -r | head -n 1)"
        if [ -n "$f" ]; then
            printf '%s/%s\n' "$VAULT_DIR/$c" "$f"
            return 0
        fi
    done
    vault_die "$EXIT_VERIFY" "vault is empty - nothing to restore"
}

main() {
    load_config
    require_passphrase
    require_driver_config

    local archive_arg="${1:-}" dest="" diff_src="" mode_test=false
    shift || true
    while [ $# -gt 0 ]; do
        case "$1" in
            --diff) diff_src="${2:-}"; shift 2 ;;
            --test) mode_test=true; shift ;;
            *) dest="$1"; shift ;;
        esac
    done

    [ -n "$archive_arg" ] || { usage; exit "$EXIT_CONFIG"; }

    local archive
    if [ "$archive_arg" = "latest" ]; then
        archive="$(pick_latest)"
    else
        case "$archive_arg" in
            */*) archive="$archive_arg" ;;
            *)   archive="$VAULT_DIR/daily/$archive_arg" ;;
        esac
    fi

    if $mode_test; then
        dest="$(mktemp -d "${TMPDIR:-/tmp}/vault-drill.XXXXXX")"
    fi
    [ -n "$dest" ] || dest="./restored-$(date '+%Y%m%dT%H%M%S')"

    local t0 t1
    t0="$(date +%s)"
    vault_log "restoring $(basename "$archive") -> $dest"
    restore_archive "$archive" "$dest"
    t1="$(date +%s)"

    if [ -n "$diff_src" ]; then
        local sub
        sub="$(find "$dest/files" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
        [ -n "$sub" ] || vault_die "$EXIT_VERIFY" "restored tree has no files/ directory"
        if diff -r "$sub" "$diff_src" >/dev/null 2>&1; then
            vault_log "diff against $diff_src: identical"
        else
            vault_die "$EXIT_VERIFY" "diff against $diff_src found differences"
        fi
    fi

    if $mode_test; then
        local rto
        rto=$((t1 - t0))
        mkdir -p "$STATE_DIR"
        date '+%Y-%m-%dT%H:%M:%S%z' > "$STATE_DIR/last-drill"
        printf '%s\n' "$rto" > "$STATE_DIR/last-drill-seconds"
        rm -rf "$dest"
        vault_log "DRILL PASSED in ${rto}s - vault is provably restorable"
    else
        vault_log "restore complete in $((t1 - t0))s: $dest"
        printf '%s\n' "$dest"
    fi
}

main "$@"
