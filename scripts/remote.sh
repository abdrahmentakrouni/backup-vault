#!/usr/bin/env bash
# backup-vault - off-site replication drivers: s3 (rclone), ssh (append-only
# vault host), dir (NAS / USB / local). Every path pushed remotely is namespaced
# by host and retention class: <host>/<class>/<archive>.
set -Eeuo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/lib.sh"

require_driver_config() {
    case "$REMOTE_TYPE" in
        s3)
            [ -n "${RCLONE_TARGET:-}" ] || vault_die "$EXIT_CONFIG" \
                "REMOTE_TYPE=s3 requires RCLONE_TARGET (example: myremote:backups)"
            need_cmd rclone
            ;;
        ssh)
            [ -n "${SSH_TARGET:-}" ] || vault_die "$EXIT_CONFIG" \
                "REMOTE_TYPE=ssh requires SSH_TARGET (user@vaulthost)"
            need_cmd ssh
            need_cmd scp
            ;;
        dir)
            [ -n "${DIR_TARGET:-}" ] || vault_die "$EXIT_CONFIG" \
                "REMOTE_TYPE=dir requires DIR_TARGET"
            mkdir -p "$DIR_TARGET"
            ;;
        *)
            vault_die "$EXIT_CONFIG" "unknown REMOTE_TYPE: $REMOTE_TYPE (s3 | ssh | dir)"
            ;;
    esac
}

remote_relpath() {
    # remote_relpath <class> <filename> -> <host>/<class>/<filename>
    printf '%s/%s/%s' "$HOSTNAME_TAG" "$1" "$2"
}

safe_name() {
    # Filenames crossing the SSH boundary must be boring on purpose: this
    # blocks command injection and path traversal on the vault host.
    case "$1" in
        *[!A-Za-z0-9._-]*|"") return 1 ;;
    esac
    case "$1" in
        .*) return 1 ;;
    esac
    return 0
}

remote_put() {
    # remote_put <local-file> <class> <remote-name>
    local file="$1" class="$2" name="$3" rel
    safe_name "$name" || vault_die "$EXIT_SHIP" "refusing unsafe vault filename: $name"
    rel="$(remote_relpath "$class" "$name")"
    case "$REMOTE_TYPE" in
        s3)
            rclone mkdir "$RCLONE_TARGET" >/dev/null 2>&1 || true
            rclone copyto "$file" "$RCLONE_TARGET/$rel"
            ;;
        ssh)
            scp -q -P "${SSH_PORT:-22}" "$file" "$SSH_TARGET:ingest/$rel"
            ;;
        dir)
            mkdir -p "$DIR_TARGET/$HOSTNAME_TAG/$class"
            cp -f "$file" "$DIR_TARGET/$rel"
            ;;
    esac
}

remote_copy_remote_to_class() {
    # Promote an archive to weekly/monthly on the remote as well.
    # remote_copy_remote_to_class <name> <from-class> <to-class>
    local name="$1" from="$2" to="$3" rel_src rel_dst
    safe_name "$name" || return 1
    rel_src="$(remote_relpath "$from" "$name")"
    rel_dst="$(remote_relpath "$to" "$name")"
    case "$REMOTE_TYPE" in
        s3)
            rclone copyto "$RCLONE_TARGET/$rel_src" "$RCLONE_TARGET/$rel_dst" >/dev/null 2>&1 || true
            ;;
        ssh)
            ssh -p "${SSH_PORT:-22}" "$SSH_TARGET" "ingest-copy $rel_src $rel_dst" >/dev/null 2>&1 || true
            ;;
        dir)
            mkdir -p "$DIR_TARGET/$HOSTNAME_TAG/$to"
            cp -f "$DIR_TARGET/$rel_src" "$DIR_TARGET/$rel_dst" 2>/dev/null || true
            ;;
    esac
}

remote_exists() {
    # remote_exists <class> <name> -> exit 0 when a copy is stored off-site
    local rel
    rel="$(remote_relpath "$1" "$2")"
    case "$REMOTE_TYPE" in
        s3)    rclone lsf "$RCLONE_TARGET/$rel" >/dev/null 2>&1 ;;
        ssh)   ssh -p "${SSH_PORT:-22}" "$SSH_TARGET" "ingest-list $rel" >/dev/null 2>&1 ;;
        dir)   [ -f "$DIR_TARGET/$rel" ] ;;
    esac
}

remote_rehash() {
    # Print the remote SHA-256 when the driver can compute one, else print
    # "size-verified:<bytes>".
    local rel
    rel="$(remote_relpath "$1" "$2")"
    case "$REMOTE_TYPE" in
        s3)
            local size
            size="$(rclone lsjson "$RCLONE_TARGET/$rel" 2>/dev/null | \
                sed -n 's/.*"Size": *\([0-9]*\).*/\1/p' | head -n 1)"
            [ -n "$size" ] && printf 'size-verified:%s\n' "$size"
            ;;
        ssh)   ssh -p "${SSH_PORT:-22}" "$SSH_TARGET" "ingest-sha256 $rel" 2>/dev/null ;;
        dir)   sha256sum "$DIR_TARGET/$rel" | cut -d ' ' -f 1 ;;
    esac
}

remote_delete() {
    # remote_delete <class> <name> - best effort, never fatal (an immutable
    # vault is allowed to refuse deletions; that is a feature, not a bug).
    local rel
    rel="$(remote_relpath "$1" "$2")"
    safe_name "$2" || return 0
    case "$REMOTE_TYPE" in
        s3)    rclone deletefile "$RCLONE_TARGET/$rel" >/dev/null 2>&1 || true ;;
        ssh)   ssh -p "${SSH_PORT:-22}" "$SSH_TARGET" "ingest-expire $rel" >/dev/null 2>&1 || true ;;
        dir)   rm -f "$DIR_TARGET/$rel" || true ;;
    esac
}

remote_pull() {
    # remote_pull <class> <name> <dest-file> - used when the local vault is
    # the thing that got destroyed.
    local rel
    rel="$(remote_relpath "$1" "$2")"
    local dest="$3"
    case "$REMOTE_TYPE" in
        s3)    rclone copyto "$RCLONE_TARGET/$rel" "$dest" ;;
        ssh)   scp -q -P "${SSH_PORT:-22}" "$SSH_TARGET:ingest/$rel" "$dest" ;;
        dir)   cp -f "$DIR_TARGET/$rel" "$dest" ;;
    esac
}

# CLI dispatch only when executed directly. When sourced, the functions
# above are what the caller wants - the caller's positional parameters must
# never reach this case statement.
if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
    case "${1:-}" in
        relpath)
            load_config
            remote_relpath "$2" "$3"
            ;;
        *)
            vault_die "$EXIT_CONFIG" "remote.sh is a library - source it, do not run it directly"
            ;;
    esac
fi
