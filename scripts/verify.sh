#!/usr/bin/env bash
# backup-vault - integrity verification for every archive in the vault.
#
#   verify.sh [--remote]
#
# Recomputes the SHA-256 of each archive and compares it with its manifest.
# --remote also asks the off-site vault for a hash (exact for the ssh and dir
# drivers, size-check for s3).
set -Eeuo pipefail
LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$LIB_DIR/lib.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/remote.sh"

CHECK_REMOTE=false
[ "${1:-}" = "--remote" ] && CHECK_REMOTE=true

main() {
    load_config
    require_driver_config
    ensure_dirs

    local total=0 failed=0 class name mf sha sha_now remote_info
    for class in daily weekly monthly; do
        for name in $(list_class_silent "$class"); do
            total=$((total + 1))
            mf="$VAULT_DIR/$class/${name%.enc}.manifest"
            if [ ! -f "$mf" ]; then
                vault_log "FAIL $class/$name: missing manifest"
                failed=$((failed + 1))
                continue
            fi
            sha="$(manifest_get sha256 "$mf")"
            sha_now="$(sha256sum "$VAULT_DIR/$class/$name" | cut -d ' ' -f 1)"
            if [ "$sha_now" != "$sha" ]; then
                vault_log "FAIL $class/$name: sha256 mismatch (vault copy altered or corrupted)"
                failed=$((failed + 1))
                continue
            fi
            remote_info="-"
            if $CHECK_REMOTE; then
                remote_info="$(remote_rehash "$class" "$name" || true)"
                [ -n "$remote_info" ] || remote_info="not-found"
            fi
            vault_log "PASS $class/$name ${remote_info:+remote=$remote_info}"
        done
    done

    if [ "$total" -eq 0 ]; then
        vault_warn "vault is empty - nothing to verify yet"
        exit "$EXIT_OK"
    fi
    if [ "$failed" -gt 0 ]; then
        bash "$LIB_DIR/notify.sh" event verify-failed \
            "$failed of $total vault archives failed integrity verification"
        vault_log "VERIFY FAILED: $failed of $total archives"
        exit "$EXIT_VERIFY"
    fi
    vault_log "VERIFY PASSED: $total archive(s), all manifests match"
}

list_class_silent() {
    local f
    for f in "$VAULT_DIR/$1"/*.enc; do
        [ -e "$f" ] || continue
        printf '%s\n' "$(basename "$f")"
    done
}

main "$@"
