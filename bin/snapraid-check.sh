#!/usr/bin/env bash
# ===============================================================
# Script:   snapraid-check.sh
# Version:  1.0.0
# Date:     2026-09-24
# Purpose:  Interactive/manual `snapraid check`: streams output live to
#           the terminal, appends it to a log, and sends a clean/errors
#           summary via ntfy and/or email (full output in the email).
#           `snapraid check` reads every block, so expect hours on a
#           large array -- run it in tmux.
# Config:   /etc/snapraid-toolkit.conf (see config/*.example)
# License:  MIT
# ===============================================================
set -uo pipefail

CONF="${SNAPRAID_TOOLKIT_CONF:-/etc/snapraid-toolkit.conf}"

NTFY_URL=""; NTFY_TOKEN=""; EMAIL_TO=""; MSMTP_ACCOUNT="default"
HOST_LABEL="$(hostname)"
CHECK_LOG_FILE="/var/log/snapraid-check.log"

# shellcheck disable=SC1090
[ -f "$CONF" ] && source "$CONF"

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: this script must be run as root." >&2
    exit 1
fi

timestamp=$(date '+%Y-%m-%d %H:%M:%S')
capture=$(mktemp /tmp/snapraid-check.XXXXXX)
trap 'rm -f "$capture"' EXIT

echo "=== SnapRAID Check Started at $timestamp ===" | tee -a "$CHECK_LOG_FILE"

snapraid check 2>&1 | tee "$capture"
check_status=${PIPESTATUS[0]}

cat "$capture" >> "$CHECK_LOG_FILE"
echo "=== SnapRAID Check Finished with exit code $check_status ===" | tee -a "$CHECK_LOG_FILE"

if [ "$check_status" -eq 0 ]; then
    status="SUCCESS"
    title="SnapRAID Check Clean - $HOST_LABEL"
    msg="SnapRAID check completed successfully. No errors found."
    priority=3; tags="white_check_mark"
else
    status="WARNING/ERROR"
    title="SnapRAID Check ERRORS - $HOST_LABEL"
    msg="SnapRAID check found issues (exit $check_status).

Summary:
$(tr '\r' '\n' < "$capture" | tail -n 5)"
    priority=5; tags="rotating_light"
fi

if [ -n "$NTFY_URL" ]; then
    auth=()
    [ -n "$NTFY_TOKEN" ] && auth=(-H "Authorization: Bearer $NTFY_TOKEN")
    curl -s -o /dev/null \
        -H "Title: $title" \
        -H "Priority: $priority" \
        -H "Tags: $tags" \
        "${auth[@]}" \
        -d "$msg" \
        "$NTFY_URL"
fi

if [ -n "$EMAIL_TO" ]; then
    # Explicit To: header -- some SMTP relays (e.g. Gmail) reject mail
    # without one even when the envelope recipient is set.
    {
        printf 'To: %s\nSubject: %s\nContent-Type: text/plain; charset=UTF-8\n\n' "$EMAIL_TO" "$title"
        printf 'Automated SnapRAID check report from %s.\n\nStatus: %s\nStarted: %s\n\nFull output:\n----------------------------------------\n' "$HOST_LABEL" "$status" "$timestamp"
        tr '\r' '\n' < "$capture"
    } | msmtp -a "$MSMTP_ACCOUNT" "$EMAIL_TO"
fi

echo "=== Notifications dispatched ===" | tee -a "$CHECK_LOG_FILE"
exit "$check_status"
