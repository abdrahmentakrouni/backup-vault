#!/usr/bin/env bash
# backup-vault - backup engine.
#
# Pipeline: canary check -> stage files -> dump databases -> tar | compress |
# openssl AES-256 -> manifest -> ship off-site -> catalog -> rotate.
# The passphrase never appears in argv (openssl reads it from the environment).
set -Eeuo pipefail
LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$LIB_DIR/lib.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/remote.sh"

STAGING=""

cleanup() {
    if [ -n "$STAGING" ] && [ -d "$STAGING" ]; then
        rm -rf "$STAGING"
    fi
}
trap cleanup EXIT

stage_files() {
    local src name
    mkdir -p "$STAGING/files"
    for src in $SOURCE_DIRS; do
        [ -d "$src" ] || vault_die "$EXIT_STAGING" "source directory does not exist: $src"
        name="$(printf '%s' "$(basename "$src")" | tr -c 'A-Za-z0-9._-' '_')"
        if [ -d "$STAGING/files/$name" ]; then
            # Two sources with the same basename: keep both, stay predictable.
            name="${name}_$$_$(printf '%s' "$src" | cksum | cut -d ' ' -f 1)"
        fi
        if command -v rsync >/dev/null 2>&1; then
            mkdir -p "$STAGING/files/$name"
            rsync -a "$src"/ "$STAGING/files/$name"/
        else
            vault_warn "rsync not found - falling back to cp (slower)"
            cp -a "$src" "$STAGING/files/$name"
        fi
    done
}

dump_databases() {
    mkdir -p "$STAGING/db"
    [ -n "$DB_NAMES" ] || vault_die "$EXIT_STAGING" "DB_ENABLED=true but DB_NAMES is empty"
    need_cmd mysqldump
    # Intentional unquoted expansion below: DB_NAMES is a whitespace-separated list.
    # shellcheck disable=SC2086
    MYSQL_PWD="$DB_PASSWORD" mysqldump \
        --single-transaction --quick --routines --triggers --events \
        --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USER" \
        --databases $DB_NAMES > "$STAGING/db/dump.sql"
    gzip -9 "$STAGING/db/dump.sql"
    [ -s "$STAGING/db/dump.sql.gz" ] || vault_die "$EXIT_STAGING" \
        "database dump came back empty - check DB credentials and privileges"
    vault_log "database dump complete: $DB_NAMES ($(du -h "$STAGING/db/dump.sql.gz" | cut -f 1))"
}

build_archive() {
    # build_archive <archive-path>
    local archive="$1" tmp_out comp_ext
    comp_ext="$(compression_ext)"
    tmp_out="${archive}.part"

    export_openssl_passphrase
    case "$COMPRESSION" in
        gzip)
            tar -C "$STAGING" -cf - files db | gzip -9 | \
                openssl enc -aes-256-cbc -pbkdf2 -iter "$ENCRYPT_ITERATIONS" \
                    -salt -pass env:VAULT_PW -out "$tmp_out"
            ;;
        xz)
            tar -C "$STAGING" -cf - files db | xz -9 -T0 | \
                openssl enc -aes-256-cbc -pbkdf2 -iter "$ENCRYPT_ITERATIONS" \
                    -salt -pass env:VAULT_PW -out "$tmp_out"
            ;;
        none)
            tar -C "$STAGING" -cf - files db | \
                openssl enc -aes-256-cbc -pbkdf2 -iter "$ENCRYPT_ITERATIONS" \
                    -salt -pass env:VAULT_PW -out "$tmp_out"
            ;;
    esac
    [ -s "$tmp_out" ] || vault_die "$EXIT_ENCRYPT" "archive came back empty"
    mv -f "$tmp_out" "$archive"
    printf '%s' "$comp_ext"
}

write_manifest() {
    # write_manifest <manifest-path> <class> <archive-name> <format> <files> <bytes>
    local mf="$1" class="$2" name="$3" format="$4" nfiles="$5" nbytes="$6"
    local sha
    sha="$(sha256sum "$VAULT_DIR/$class/$name" | cut -d ' ' -f 1)"
    {
        printf 'manifest-version=1\n'
        printf 'host=%s\n' "$HOSTNAME_TAG"
        printf 'created=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
        printf 'class=%s\n' "$class"
        printf 'archive=%s\n' "$name"
        printf 'format=%s\n' "$format"
        printf 'encryption=aes-256-cbc\n'
        printf 'kdf=pbkdf2\n'
        printf 'iterations=%s\n' "$ENCRYPT_ITERATIONS"
        printf 'size-bytes=%s\n' "$(stat -c '%s' "$VAULT_DIR/$class/$name")"
        printf 'sha256=%s\n' "$sha"
        printf 'files=%s\n' "$nfiles"
        printf 'bytes-uncompressed=%s\n' "$nbytes"
        printf 'databases=%s\n' "$DB_NAMES"
        printf 'source-dirs=%s\n' "$SOURCE_DIRS"
    } > "$mf"
    printf '%s' "$sha"
}

main() {
    load_config
    require_passphrase
    need_cmd tar
    need_cmd openssl
    need_cmd sha256sum
    need_cmd date
    require_driver_config
    ensure_dirs

    # 1. Ransomware tripwire - before touching the vault.
    if ! bash "$LIB_DIR/canary.sh" check >/dev/null 2>&1; then
        bash "$LIB_DIR/notify.sh" event tripwire \
            "backup aborted: canary files changed on $HOSTNAME_TAG - suspected ransomware, vault left untouched"
        bash "$LIB_DIR/canary.sh" check
        exit "$EXIT_TRIPWIRE"
    fi

    # 2. Stage.
    STAGING="$(mktemp -d "$VAULT_DIR/.staging.XXXXXX")"
    mkdir -p "$STAGING/files" "$STAGING/db"
    vault_log "staging sources: $SOURCE_DIRS"
    stage_files

    # 3. Databases - a file-only backup of a database server is a time bomb.
    if [ "$DB_ENABLED" = "true" ]; then
        dump_databases
    fi

    local nfiles nbytes
    nfiles="$(find "$STAGING" -type f | wc -l)"
    nbytes="$(du -sb "$STAGING" | cut -f 1)"

    # 4. Encrypt + write vault artifacts.
    local class="daily"
    local ext name archive mf sha
    ext="$(compression_ext)"
    name="$(printf '%s-%s.%s.enc' "$HOSTNAME_TAG" "$(date -u '+%Y%m%dT%H%M%SZ')" "$ext")"
    archive="$VAULT_DIR/$class/$name"
    mf="${archive%.enc}.manifest"
    vault_log "compressing and encrypting ($COMPRESSION, aes-256-cbc, pbkdf2 x$ENCRYPT_ITERATIONS)"
    local format
    format="$(build_archive "$archive")" || exit "$EXIT_ENCRYPT"
    sha="$(write_manifest "$mf" "$class" "$name" "$format" "$nfiles" "$nbytes")"

    # 5. Ship off-site (local copy survives even if shipping fails, loudly).
    if remote_put "$archive" "$class" "$name" && remote_put "$mf" "$class" "$(basename "$mf")"; then
        vault_log "off-site copy stored: $REMOTE_TYPE ($HOSTNAME_TAG/$class/$name)"
    else
        bash "$LIB_DIR/notify.sh" event ship-failed \
            "off-site copy failed for $name - local vault is intact, investigate connectivity"
        vault_die "$EXIT_SHIP" "off-site copy failed for $name (exit code $EXIT_SHIP)"
    fi

    # 6. Catalog + heartbeat.
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u '+%Y-%m-%d')" "$class" "$name" \
        "$(stat -c '%s' "$archive")" "$sha" >> "$VAULT_DIR/catalog.tsv"
    bash "$LIB_DIR/notify.sh" heartbeat
    vault_log "archive sealed: $archive ($(du -h "$archive" | cut -f 1), $nfiles files)"

    # 7. Rotate (promotion + pruning, local and remote).
    if ! bash "$LIB_DIR/rotate.sh" >/dev/null 2>&1; then
        bash "$LIB_DIR/notify.sh" event rotate-failed \
            "retention rotation reported errors - check vault permissions"
        vault_warn "rotation failed - see previous messages"
    fi

    vault_log "done. verify integrity with: bash vault.sh verify"
}

main "$@"
