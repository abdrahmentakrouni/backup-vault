#!/usr/bin/env bash
# backup-vault - grandfather-father-son retention rotation.
#
# Promotions:  Mondays  -> today's archive is copied to weekly/
#              the 1st  -> today's archive is copied to monthly/
# Pruning:     keep the newest RETENTION_DAILY / _WEEKLY / _MONTHLY archives
#              per class (locally, and on the remote when PRUNE_REMOTE=true).
set -Eeuo pipefail
LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$LIB_DIR/lib.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/remote.sh"

DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

list_class() {
    # list_class <dir> -> archive names, newest stamp first
    local dir="$1" f
    [ -d "$dir" ] || return 0
    for f in "$dir"/*.enc; do
        [ -e "$f" ] || continue
        printf '%s\n' "$(basename "$f")"
    done | sort -r
}

prune_class() {
    # prune_class <class> <keep-count>
    local class="$1" keep="$2"
    local dir="$VAULT_DIR/$class"
    local total=0 deleted=0 name mf
    local names
    names="$(list_class "$dir")"
    [ -n "$names" ] || return 0
    total="$(printf '%s\n' "$names" | wc -l)"
    if [ "$total" -le "$keep" ]; then
        vault_log "retention $class: $total archive(s) kept (limit $keep)"
        return 0
    fi
    local expired name mf deleted=0
    expired="$(printf '%s\n' "$names" | tail -n "+$((keep + 1))")"
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        mf="${name%.enc}.manifest"
        if $DRY_RUN; then
            vault_log "retention $class (dry-run): would delete $name"
        else
            rm -f "$dir/$name" "$dir/$mf"
            if [ "$PRUNE_REMOTE" = "true" ]; then
                remote_delete "$class" "$name"
                remote_delete "$class" "$mf"
            fi
        fi
        deleted=$((deleted + 1))
    done <<< "$expired"
    if $DRY_RUN; then
        vault_log "retention $class (dry-run): $deleted archive(s) would be pruned (limit $keep)"
    else
        vault_log "retention $class: pruned $deleted archive(s) (limit $keep)"
    fi
    return 0
}

promote() {
    # promote <name> <to-class>
    local name="$1" to="$2"
    local src="$VAULT_DIR/daily/$name"
    local mf="${name%.enc}.manifest"
    [ -f "$src" ] || return 0
    if $DRY_RUN; then
        vault_log "promotion (dry-run): $name -> $to/"
        return 0
    fi
    cp -f "$src" "$VAULT_DIR/$to/$name"
    [ -f "$VAULT_DIR/daily/$mf" ] && cp -f "$VAULT_DIR/daily/$mf" "$VAULT_DIR/$to/$mf"
    remote_copy_remote_to_class "$name" daily "$to"
    [ -f "$VAULT_DIR/daily/$mf" ] && remote_copy_remote_to_class "$(basename "$mf")" daily "$to"
    vault_log "promotion: $name -> $to/"
}

main() {
    load_config
    require_driver_config
    ensure_dirs

    # Promote today's newest daily archive (if any) per calendar rules.
    local newest to
    newest="$(list_class "$VAULT_DIR/daily" | head -n 1 || true)"
    if [ -n "$newest" ]; then
        while IFS= read -r to; do
            [ -n "$to" ] || continue
            promote "$newest" "$to"
        done <<EOF
$(today_class_promotions)
EOF
    fi

    prune_class daily "$RETENTION_DAILY"
    prune_class weekly "$RETENTION_WEEKLY"
    prune_class monthly "$RETENTION_MONTHLY"

    if $DRY_RUN; then
        vault_log "rotation dry-run complete - nothing was changed"
    else
        vault_log "rotation complete (daily=$RETENTION_DAILY weekly=$RETENTION_WEEKLY monthly=$RETENTION_MONTHLY)"
    fi
}

main "$@"
