#!/usr/bin/env bash
# ===============================================================
# Script:   snapraid-scrub-trigger.sh
# Version:  1.0.0
# Date:     2026-09-24
# Purpose:  Day-gate for SnapRAID scrub. Run via systemd OnSuccess= from
#           snapraid-sync.service, so a scrub only ever starts after that
#           night's sync has genuinely finished (a fixed-time scrub timer
#           can't know how long a sync will take -- anywhere from minutes
#           to hours). Hands off to snapraid-scrub.sh once at least
#           SCRUB_MIN_GAP_DAYS have passed since the last scrub.
#           Only READS the state file; snapraid-scrub.sh writes it.
# Config:   /etc/snapraid-toolkit.conf (see config/*.example)
# License:  MIT
# ===============================================================
set -euo pipefail

CONF="${SNAPRAID_TOOLKIT_CONF:-/etc/snapraid-toolkit.conf}"

SCRUB_STATE_FILE="/var/lib/snapraid/last-scrub-run"
SCRUB_MIN_GAP_DAYS=7
LOG_FILE="/var/log/snapraid.log"
SCRUB_SCRIPT="$(dirname "$(readlink -f "$0")")/snapraid-scrub.sh"

# shellcheck disable=SC1090
[ -f "$CONF" ] && source "$CONF"

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - [SCRUB-TRIGGER] $*" | tee -a "$LOG_FILE"
}

if [ -f "$SCRUB_STATE_FILE" ]; then
    age_days=$(( ( $(date +%s) - $(stat -c %Y "$SCRUB_STATE_FILE") ) / 86400 ))
    if [ "$age_days" -lt "$SCRUB_MIN_GAP_DAYS" ]; then
        log_message "Last scrub was ${age_days} day(s) ago (need ${SCRUB_MIN_GAP_DAYS}). Not due yet, skipping."
        exit 0
    fi
fi

log_message "Scrub is due -- handing off to $SCRUB_SCRIPT"
exec "$SCRUB_SCRIPT"
