#!/usr/bin/env bash
# backup-vault - shared helpers loaded by every entry script.
# shellcheck shell=bash

# Constants are consumed by the scripts that source this library.
# shellcheck disable=SC2034
BACKUP_VAULT_VERSION="1.0.0"

# Documented exit codes (see README and docs/architecture.md)
EXIT_OK=0
EXIT_CONFIG=10
EXIT_STAGING=20
EXIT_ENCRYPT=30
EXIT_SHIP=40
EXIT_TRIPWIRE=42
EXIT_VERIFY=50
EXIT_AUDIT=60

vault_log() {
    printf '[backup-vault] %s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"
}

vault_warn() {
    printf '[backup-vault] WARN: %s\n' "$*" >&2
}

vault_die() {
    local code="$1"
    shift
    printf '[backup-vault] FATAL: %s\n' "$*" >&2
    exit "$code"
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || \
        vault_die "$EXIT_CONFIG" "required command not found: $1"
}

# Load the configuration file, then let environment variables win.
load_config() {
    CONFIG_FILE="${VAULT_CONFIG:-/etc/backup-vault/vault.conf}"
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        . "$CONFIG_FILE"
    elif [ -n "${VAULT_CONFIG:-}" ]; then
        vault_die "$EXIT_CONFIG" "config file set but missing: $CONFIG_FILE"
    fi

    VAULT_DIR="${VAULT_DIR:-/var/backup-vault}"
    STATE_DIR="${STATE_DIR:-/var/lib/backup-vault}"
    SOURCE_DIRS="${SOURCE_DIRS:-/srv/data}"
    ENCRYPT_ITERATIONS="${ENCRYPT_ITERATIONS:-300000}"
    COMPRESSION="${COMPRESSION:-gzip}"
    DB_ENABLED="${DB_ENABLED:-false}"
    DB_HOST="${DB_HOST:-127.0.0.1}"
    DB_PORT="${DB_PORT:-3306}"
    DB_USER="${DB_USER:-backup}"
    DB_NAMES="${DB_NAMES:-}"
    REMOTE_TYPE="${REMOTE_TYPE:-dir}"
    PRUNE_REMOTE="${PRUNE_REMOTE:-true}"
    RETENTION_DAILY="${RETENTION_DAILY:-7}"
    RETENTION_WEEKLY="${RETENTION_WEEKLY:-4}"
    RETENTION_MONTHLY="${RETENTION_MONTHLY:-12}"
    CANARY_DIR="${CANARY_DIR:-/opt/canary}"
    CANARY_BASELINE="${CANARY_BASELINE:-$STATE_DIR/canary.sha256}"
    HEARTBEAT_FILE="${HEARTBEAT_FILE:-$STATE_DIR/heartbeat}"
    NOTIFY_WEBHOOK="${NOTIFY_WEBHOOK:-}"
    RPO_HOURS="${RPO_HOURS:-24}"
    HOSTNAME_TAG="$(hostname -s 2>/dev/null || hostname)"
    # Keep host tags filesystem- and manifest-safe.
    HOSTNAME_TAG="$(printf '%s' "$HOSTNAME_TAG" | tr -c 'A-Za-z0-9._-' '_')"
}

# Passphrase resolution: env var, then protected file, then failure.
require_passphrase() {
    if [ -z "${BACKUP_PASSPHRASE:-}" ] && [ -n "${BACKUP_PASSPHRASE_FILE:-}" ] \
        && [ -f "$BACKUP_PASSPHRASE_FILE" ]; then
        BACKUP_PASSPHRASE="$(tr -d '\r\n' < "$BACKUP_PASSPHRASE_FILE")"
        export BACKUP_PASSPHRASE
    fi
    [ -n "${BACKUP_PASSPHRASE:-}" ] || vault_die "$EXIT_CONFIG" \
        "no passphrase: set BACKUP_PASSPHRASE or BACKUP_PASSPHRASE_FILE"
    [ "${#BACKUP_PASSPHRASE}" -ge 12 ] || vault_die "$EXIT_CONFIG" \
        "passphrase too short (minimum 12 characters) - weak keys make encryption theater"
}

# openssl reads the passphrase from the environment, never from argv.
export_openssl_passphrase() {
    VAULT_PW="$BACKUP_PASSPHRASE"
    export VAULT_PW
}

compression_ext() {
    case "$COMPRESSION" in
        gzip) printf 'tar.gz' ;;
        xz)   printf 'tar.xz' ;;
        none) printf 'tar' ;;
        *) vault_die "$EXIT_CONFIG" "unknown COMPRESSION: $COMPRESSION" ;;
    esac
}

# Extract "key=value" from a manifest file.
manifest_get() {
    local key="$1" file="$2"
    grep "^${key}=" "$file" | head -n 1 | cut -d '=' -f 2-
}

json_escape() {
    # Messages are restricted to a safe charset before embedding in JSON.
    printf '%s' "$1" | tr -c 'A-Za-z0-9 .,:;()_%@/\n' ' '
}

ensure_dirs() {
    mkdir -p "$VAULT_DIR/daily" "$VAULT_DIR/weekly" "$VAULT_DIR/monthly" "$STATE_DIR"
}

today_class_promotions() {
    # stdout: classes today's backup should be promoted to (besides daily).
    local dow dom
    dow="$(date +%u)"   # 1=Monday ... 7=Sunday
    dom="$(date +%-d)"
    [ "$dow" = "1" ] && printf 'weekly\n'
    [ "$dom" = "1" ] && printf 'monthly\n'
    return 0
}
