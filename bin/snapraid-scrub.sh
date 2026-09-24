#!/usr/bin/env bash
# ===============================================================
# Script:   snapraid-scrub.sh
# Version:  1.0.0
# Date:     2026-09-24
# Purpose:  SnapRAID scrub (`scrub -p SCRUB_PERCENT`), normally started by
#           snapraid-scrub-trigger.sh after a successful nightly sync
#           rather than by a fixed-time timer, so it never races the sync.
#           Writes SCRUB_STATE_FILE only after acquiring its own lock, so
#           a lock-collision no-op can't falsely mark a cycle as done.
#           Appends `snapraid status` to the log after a clean scrub.
# Config:   /etc/snapraid-toolkit.conf (see config/*.example)
# License:  MIT
# ===============================================================
set -uo pipefail

CONF="${SNAPRAID_TOOLKIT_CONF:-/etc/snapraid-toolkit.conf}"

NTFY_URL=""; NTFY_TOKEN=""; EMAIL_TO=""; MSMTP_ACCOUNT="default"
HOST_LABEL="$(hostname)"
LOG_FILE="/var/log/snapraid.log"
SCRUB_PERCENT=8
SCRUB_STATE_FILE="/var/lib/snapraid/last-scrub-run"
LOCK_FILE="/var/lock/snapraid-scrub.lock"
SYNC_LOCK_FILE="/var/lock/snapraid-sync.lock"

# shellcheck disable=SC1090
[ -f "$CONF" ] && source "$CONF"

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - [SCRUB] $*" | tee -a "$LOG_FILE"
}

send_notification() {
    local subject="$1"
    local message="$2"
    local priority="3"
    local tags="warning"
    local full_message="$message"

    if [[ "$subject" == *FAIL* ]]; then
        priority="5"
        tags="rotating_light"
        full_message=$(printf '%s\n\n--- Recent Log Entries ---\n%s' "$message" "$(tail -n 20 "$LOG_FILE")")
    fi

    log_message "ALERT: Sending notification: $subject"

    if [ -n "$EMAIL_TO" ]; then
        printf "Subject: %s\n\n%s\n" "$subject" "$full_message" | msmtp -a "$MSMTP_ACCOUNT" "$EMAIL_TO"
    fi

    if [ -n "$NTFY_URL" ]; then
        local auth=()
        [ -n "$NTFY_TOKEN" ] && auth=(-H "Authorization: Bearer $NTFY_TOKEN")
        curl -s \
            -H "Title: $subject" \
            -H "Priority: $priority" \
            -H "Tags: $tags" \
            "${auth[@]}" \
            -d "$full_message" \
            "$NTFY_URL" > /dev/null
    fi
}

cleanup() {
    rm -f "$LOCK_FILE"
}
trap cleanup EXIT

# --- Main Execution ---
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root."
    exit 1
fi

if [ -e "$LOCK_FILE" ]; then
    existing_pid=$(cat "$LOCK_FILE" 2>/dev/null)
    if [ -n "$existing_pid" ] && [ -d "/proc/$existing_pid" ]; then
        log_message "Another snapraid-scrub run is in progress (PID $existing_pid). Exiting."
        exit 1
    fi
    log_message "Stale lock file found; removing."
    rm -f "$LOCK_FILE"
fi

if [ -e "$SYNC_LOCK_FILE" ]; then
    sync_pid=$(cat "$SYNC_LOCK_FILE" 2>/dev/null)
    if [ -n "$sync_pid" ] && [ -d "/proc/$sync_pid" ]; then
        log_message "Sync is currently running (PID $sync_pid). Deferring scrub."
        exit 0
    fi
fi

echo $$ > "$LOCK_FILE"
mkdir -p "$(dirname "$SCRUB_STATE_FILE")"
touch "$SCRUB_STATE_FILE"

log_message "Starting SnapRAID Scrub on $HOST_LABEL..."
log_message "Running snapraid scrub -p $SCRUB_PERCENT..."
scrub_tmp=$(mktemp /tmp/snapraid-scrub.XXXXXX)
snapraid scrub -p "$SCRUB_PERCENT" 2>&1 | tee -a "$LOG_FILE" > "$scrub_tmp"
scrub_status=${PIPESTATUS[0]}

if [ "$scrub_status" -ne 0 ]; then
    scrub_tail=$(tail -n 50 "$scrub_tmp")
    rm -f "$scrub_tmp"
    send_notification "SnapRAID SCRUB FAIL" "Scrub failed on $HOST_LABEL (exit $scrub_status).

--- snapraid scrub output (tail) ---
$scrub_tail"
    exit 1
fi

rm -f "$scrub_tmp"
log_message "Scrub Complete Successfully."

{
    echo "--- SnapRAID Status Snapshot ---"
    snapraid status
    echo "--------------------------------"
} >> "$LOG_FILE" 2>&1

exit 0
