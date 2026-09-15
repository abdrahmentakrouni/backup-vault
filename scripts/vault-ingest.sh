#!/bin/sh
# backup-vault - append-only ingest wrapper for the SSH vault host.
#
# The backup servers are the machines most likely to get popped by ransomware,
# so they must NOT hold delete rights on the vault. This wrapper is forced by
# authorized_keys and only accepts append-style operations:
#
#   put <class>/<file>       store a new object (refuses to overwrite)
#   ingest-copy <src> <dst>  promote daily -> weekly/monthly (refuses overwrite)
#   ingest-list <class>/<file>
#   ingest-sha256 <class>/<file>
#   ingest-expire <class>/<file>   move to expired/ for out-of-band cleanup
#
# Install on the vault host:
#   1. sudo install -m 0755 scripts/vault-ingest.sh /usr/local/bin/vault-ingest
#   2. create the vault user, then in its authorized_keys force the wrapper:
#      command="/usr/local/bin/vault-ingest",restrict ssh-ed25519 AAAA... backup@web01
#
# Deletion is deliberately absent: a compromised backup server cannot wipe the
# vault. Expired archives are quarantined (ingest-expire) and cleaned by a
# human or an out-of-band cron on the vault host itself.

VAULT_ROOT="${VAULT_ROOT:-/srv/backup-vault}"
LOG="${VAULT_ROOT%/}/ingest.log"

log() {
    printf '%s %s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "${SSH_CONNECTION:-local}" "$*" >> "$LOG" 2>/dev/null || true
}

refuse() {
    log "REFUSED cmd=[$SSH_ORIGINAL_COMMAND] from=${SSH_CLIENT:-unknown}"
    printf 'vault-ingest: operation not permitted: %s\n' "$SSH_ORIGINAL_COMMAND" >&2
    exit 77
}

# Object names must be boring: exactly <host>/<class>/<file>, charset
# [A-Za-z0-9._-], no traversal, no shell metacharacters.
safe_rel() {
    printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._/-]*$' || return 1
    case "$1" in *..*) return 1 ;; esac
    case "$1" in
        */*/*) : ;;
        *) return 1 ;;
    esac
    case "$1" in
        */*/*/*) return 1 ;;
    esac
    return 0
}

abspath() {
    # safe_rel has already validated the shape <host>/<class>/<file>
    printf '%s/%s' "$VAULT_ROOT" "$1"
}

CMD="${SSH_ORIGINAL_COMMAND:-}"
if [ -z "$CMD" ] || [ -z "${SSH_CONNECTION:-}" ]; then
    refuse
fi
# strip the wrapper name, keep arguments
ARGS="${CMD#vault-ingest }"
[ "$ARGS" != "$CMD" ] || refuse
OP="${ARGS%% *}"
ARG="${ARGS#* }"
[ "$OP" != "$ARGS" ] || { ARG=""; }
# ops that need no argument fall through below

mkdir -p "$VAULT_ROOT/daily" "$VAULT_ROOT/weekly" "$VAULT_ROOT/monthly" \
         "$VAULT_ROOT/expired" 2>/dev/null || true

case "$OP" in
    put)
        [ -n "$ARG" ] || refuse
        safe_rel "$ARG" || refuse
        DST="$(abspath "$ARG")"
        if [ -e "$DST" ]; then
            log "REJECTED duplicate put=[$ARG]"
            printf 'vault-ingest: object already exists (append-only): %s\n' "$ARG" >&2
            exit 78
        fi
        mkdir -p "$(dirname "$DST")"
        umask 077
        cat > "$DST.part.$$" && mv -f "$DST.part.$$" "$DST"
        log "PUT $ARG"
        ;;
    ingest-copy)
        SRC="${ARG%% *}"
        DST="${ARG#* }"
        safe_rel "$SRC" || refuse
        safe_rel "$DST" || refuse
        S="$(abspath "$SRC")"; D="$(abspath "$DST")"
        [ -f "$S" ] || exit 79
        [ -e "$D" ] || cp -f "$S" "$D"
        log "COPY $SRC -> $DST"
        ;;
    ingest-list)
        safe_rel "$ARG" || refuse
        [ -f "$(abspath "$ARG")" ] || exit 80
        log "LIST $ARG"
        ;;
    ingest-sha256)
        safe_rel "$ARG" || refuse
        F="$(abspath "$ARG")"
        [ -f "$F" ] || exit 80
        sha256sum "$F" | cut -d ' ' -f 1
        log "SHA256 $ARG"
        ;;
    ingest-expire)
        safe_rel "$ARG" || refuse
        F="$(abspath "$ARG")"
        [ -f "$F" ] || exit 80
        mv -f "$F" "$VAULT_ROOT/expired/$(printf '%s' "$ARG" | tr '/' '_')"
        log "EXPIRE $ARG"
        ;;
    *)
        refuse
        ;;
esac
