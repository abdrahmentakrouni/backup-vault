#!/usr/bin/env bash
# backup-vault - alerting hooks: webhook events + heartbeat for dead-man switch.
set -Eeuo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/lib.sh"

send_event() {
    local type="$1"
    shift
    local message
    message="$(json_escape "$*")"
    vault_log "event=$type $message"
    if [ -n "$NOTIFY_WEBHOOK" ] && command -v curl >/dev/null 2>&1; then
        curl -fsS -m 10 -X POST \
            -H 'Content-Type: application/json' \
            -d "{\"service\":\"backup-vault\",\"host\":\"$HOSTNAME_TAG\",\"event\":\"$type\",\"message\":\"$message\"}" \
            "$NOTIFY_WEBHOOK" >/dev/null 2>&1 || \
            vault_warn "webhook delivery failed (continuing)"
    fi
}

touch_heartbeat() {
    mkdir -p "$(dirname "$HEARTBEAT_FILE")"
    date '+%Y-%m-%dT%H:%M:%S%z' > "$HEARTBEAT_FILE"
}

case "${1:-}" in
    event)
        # config first: send_event needs HOSTNAME_TAG and NOTIFY_WEBHOOK
        load_config
        send_event "${2:-unknown}" "${3:-}" "${4:-}"
        ;;
    heartbeat)
        load_config
        touch_heartbeat
        vault_log "heartbeat refreshed: $HEARTBEAT_FILE"
        ;;
    *)
        vault_die "$EXIT_CONFIG" "usage: notify.sh event <type> <message> | heartbeat"
        ;;
esac
