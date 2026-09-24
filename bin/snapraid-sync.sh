#!/usr/bin/env bash
# ===============================================================
# Script:   snapraid-sync.sh
# Version:  1.0.0
# Date:     2026-09-24
# Purpose:  Nightly SnapRAID `touch` + `sync` that first quiesces the
#           things writing to the array:
#             1. waits (bounded) for Sonarr/Radarr/Lidarr imports to finish
#             2. optionally enters Uptime Kuma maintenance windows
#             3. `docker pause`s PAUSE_CONTAINERS (locally or over SSH)
#           then syncs, and ALWAYS unpauses + health-checks the containers
#           and exits maintenance on the way out (trap on EXIT).
#           Alerts via ntfy and/or msmtp email on failure.
# Config:   /etc/snapraid-toolkit.conf (see config/*.example)
# License:  MIT
#
# Design notes (each one learned from a real failure):
# - Remote `docker inspect` calls use ONE simple '{{.Field}}' template each.
#   ssh flattens argv into a single string that the remote login shell
#   re-parses, so a combined template like '{{.A}}|{{if .B}}...' loses its
#   quoting on the wire: the '|' becomes a real pipe and the call silently
#   returns nothing, stalling the health poll.
# - Unpause is two-phase: unpause everything first, then round-robin the
#   health checks. A sequential "unpause, wait for healthy, next" loop lets
#   one slow container block every other container from being resumed.
# - A pause is verified by re-reading the live state, not by trusting
#   `docker pause`'s exit status.
# - An already-unpaused container (resumed by some other job) counts as
#   success, not as a failed unpause.
# - The *arr quiesce check exists because a fixed pause time cannot know an
#   import is in progress: a multi-GB file caught mid-copy produces tens of
#   thousands of SnapRAID block errors and fails the whole run. It is
#   best-effort: if an API can't be reached it logs a warning and proceeds.
# - Sync and scrub each defer to the other's lock file.
# ===============================================================
set -uo pipefail

CONF="${SNAPRAID_TOOLKIT_CONF:-/etc/snapraid-toolkit.conf}"

# --- Defaults (overridden by $CONF) ---
NTFY_URL=""; NTFY_TOKEN=""; EMAIL_TO=""; MSMTP_ACCOUNT="default"
HOST_LABEL="$(hostname)"
PARITY_MOUNT="/mnt/parity1"
PARITY_WARN_PERCENT=98
LOG_FILE="/var/log/snapraid.log"
PAUSE_CONTAINERS=()
DOCKER_SSH_DEST=""
ARR_INSTANCES=()
ARR_QUIET_MAX_RETRIES=8
ARR_QUIET_RETRY_DELAY=15
KUMA_MAINTENANCE=()
KUMA_HELPER="/usr/local/bin/kuma-maintenance.py"
KUMA_CREDENTIALS_FILE="/root/.config/kuma.env"
LOCK_FILE="/var/lock/snapraid-sync.lock"
SCRUB_LOCK_FILE="/var/lock/snapraid-scrub.lock"

# Unpause verification: some containers (e.g. Nextcloud) take a couple of
# minutes to report healthy. Poll for up to 5 minutes (30 x 10s).
UNPAUSE_RETRIES=3
UNPAUSE_RETRY_DELAY=2
HEALTH_MAX_RETRIES=30
HEALTH_RETRY_DELAY=10

# shellcheck disable=SC1090
[ -f "$CONF" ] && source "$CONF"

kuma_maintenance_active=0
paused_list=()

# --- Functions ---
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - [SYNC] $*" | tee -a "$LOG_FILE"
}

# Runs a command on the Docker host: locally, or via ssh if DOCKER_SSH_DEST
# is set. Keep arguments free of shell metacharacters -- see design notes.
docker_host() {
    if [ -n "$DOCKER_SSH_DEST" ]; then
        ssh -o BatchMode=yes "$DOCKER_SSH_DEST" "$@"
    else
        "$@"
    fi
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
        # Drop progress-bar lines (they contain both a % and a |) so the
        # attached log tail is readable.
        local log_tail
        log_tail=$(tail -n 25 "$LOG_FILE" | grep -Ev '%.*\|')
        full_message=$(printf '%s\n\n--- Recent Log Entries ---\n%s' "$message" "$log_tail")
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

# Reads an *arr app's API key out of its own config.xml. Sends only a plain
# `cat <path>` to the Docker host and parses locally -- a remote grep with
# regex metacharacters would be re-parsed by the remote login shell (which
# breaks outright under non-POSIX shells like fish).
arr_api_key() {
    local xml_path="$1"
    local xml
    xml=$(docker_host cat "$xml_path" 2>/dev/null) || return 1
    printf '%s' "$xml" | grep -oP '(?<=<ApiKey>)[^<]+'
}

# Prints active command names and returns 0 if the *arr instance has an
# import/scan command running or queued; returns 1 if quiet OR if the API
# couldn't be reached/parsed (the caller treats both as "go ahead").
arr_has_active_command() {
    local url="$1" key="$2"
    curl -s -m 10 -H "X-Api-Key: $key" "$url/api/v3/command" 2>/dev/null | python3 -c "
import json, sys
try:
    cmds = json.load(sys.stdin)
except Exception:
    sys.exit(1)
active = [c.get('name', '?') for c in cmds if c.get('status') in ('started', 'queued')]
if active:
    print(','.join(active))
    sys.exit(0)
sys.exit(1)
"
}

wait_for_arr_quiet() {
    local entry
    for entry in "${ARR_INSTANCES[@]}"; do
        local app url xml_path key
        IFS='|' read -r app url xml_path <<< "$entry"
        key=$(arr_api_key "$xml_path")
        if [ -z "$key" ]; then
            log_message "WARN: could not read $app's API key from $xml_path; skipping quiesce check for $app."
            continue
        fi

        local attempt=1 active="" waited=0
        while [ "$attempt" -le "$ARR_QUIET_MAX_RETRIES" ]; do
            if ! active=$(arr_has_active_command "$url" "$key"); then
                break
            fi
            waited=1
            log_message "$app has an active command [$active]; waiting before pausing (attempt $attempt/$ARR_QUIET_MAX_RETRIES)..."
            sleep "$ARR_QUIET_RETRY_DELAY"
            attempt=$((attempt + 1))
        done

        if [ "$attempt" -gt "$ARR_QUIET_MAX_RETRIES" ]; then
            log_message "WARN: $app still busy after $((ARR_QUIET_MAX_RETRIES * ARR_QUIET_RETRY_DELAY))s; pausing anyway (may still race a slow import)."
        elif [ "$waited" -eq 1 ]; then
            log_message "$app is quiet now, proceeding."
        fi
    done
}

# Enter/exit every configured Kuma maintenance window. Failing to ENTER is
# only logged (worst case: a false-positive Kuma alert). Failing to EXIT is
# alerted on, because a stuck window silently suppresses real alerts.
kuma_maintenance() {
    local action="$1" ok=1 entry url id
    [ "${#KUMA_MAINTENANCE[@]}" -gt 0 ] || return 0
    if [ ! -f "$KUMA_CREDENTIALS_FILE" ] || [ ! -x "$KUMA_HELPER" ]; then
        log_message "WARN: Kuma helper or credentials missing; skipping maintenance $action."
        return 0
    fi
    # shellcheck disable=SC1090
    source "$KUMA_CREDENTIALS_FILE"
    for entry in "${KUMA_MAINTENANCE[@]}"; do
        IFS='|' read -r url id <<< "$entry"
        KUMA_PASSWORD="$KUMA_PASSWORD" "$KUMA_HELPER" "$action" --url "$url" --user "$KUMA_USER" --id "$id" >>"$LOG_FILE" 2>&1 || ok=0
    done
    [ "$ok" -eq 1 ]
}

kuma_maintenance_enter() {
    [ "${#KUMA_MAINTENANCE[@]}" -gt 0 ] || return 0
    # Mark active even on partial failure so cleanup exits whichever
    # instance(s) DID enter, rather than leaving one stuck on.
    kuma_maintenance_active=1
    if kuma_maintenance enter; then
        log_message "Entered Kuma maintenance window(s)."
    else
        log_message "WARN: Failed to enter one or more Kuma maintenance windows; Kuma may alert during the pause."
    fi
}

kuma_maintenance_exit() {
    if kuma_maintenance exit; then
        log_message "Exited Kuma maintenance window(s)."
    else
        send_notification "SnapRAID KUMA MAINTENANCE STUCK" "Failed to exit one or more Uptime Kuma maintenance windows after SnapRAID sync on $HOST_LABEL. Clear maintenance mode manually in the Kuma UI -- until then, real alerts for the affected monitors are suppressed."
    fi
}

# One simple template per call -- see design notes.
docker_state() {
    docker_host docker inspect --format '{{.State.Status}}' "$1" 2>/dev/null
}

docker_health() {
    local h
    h=$(docker_host docker inspect --format '{{.State.Health.Status}}' "$1" 2>/dev/null)
    echo "${h:-none}"
}

docker_paused() {
    docker_host docker inspect --format '{{.State.Paused}}' "$1" 2>/dev/null
}

verify_and_unpause() {
    local failures=()
    local pending=()
    local c

    # --- Phase 1: unpause everything ---
    for c in "${paused_list[@]}"; do
        if [ "$(docker_paused "$c")" = "false" ]; then
            log_message "Container $c is already unpaused (resumed by something else)."
            pending+=("$c")
            continue
        fi

        local unpause_ok=0 attempt
        for attempt in $(seq 1 "$UNPAUSE_RETRIES"); do
            if docker_host docker unpause "$c" >/dev/null 2>&1; then
                unpause_ok=1
                break
            fi
            log_message "WARN: docker unpause $c failed (attempt $attempt/$UNPAUSE_RETRIES), retrying..."
            sleep "$UNPAUSE_RETRY_DELAY"
        done

        if [ "$unpause_ok" -eq 0 ]; then
            log_message "ERROR: Failed to unpause container: $c after $UNPAUSE_RETRIES attempts"
            failures+=("$c: 'docker unpause' failed after $UNPAUSE_RETRIES attempts (possible connectivity issue to the Docker host)")
            continue
        fi
        log_message "Unpaused container: $c"
        pending+=("$c")
    done

    # --- Phase 2: round-robin health poll across all unpaused containers ---
    local attempt=1
    while [ "${#pending[@]}" -gt 0 ] && [ "$attempt" -le "$HEALTH_MAX_RETRIES" ]; do
        local still_pending=()
        for c in "${pending[@]}"; do
            local state health
            state=$(docker_state "$c")
            health=$(docker_health "$c")
            if [ "$state" = "running" ] && { [ "$health" = "healthy" ] || [ "$health" = "none" ]; }; then
                log_message "Container $c is now: $state (Health: $health)"
            else
                still_pending+=("$c")
            fi
        done
        pending=("${still_pending[@]}")
        if [ "${#pending[@]}" -gt 0 ]; then
            local joined
            joined=$(printf '%s, ' "${pending[@]}")
            log_message "Still waiting on: ${joined%, } (attempt $attempt/$HEALTH_MAX_RETRIES)"
            sleep "$HEALTH_RETRY_DELAY"
        fi
        attempt=$((attempt + 1))
    done

    for c in "${pending[@]}"; do
        local state health
        state=$(docker_state "$c")
        health=$(docker_health "$c")
        log_message "ERROR: Container $c failed to reach a healthy state within timeout (final: $state, Health: $health)"
        failures+=("$c: stuck at '$state' (Health: $health) after $((HEALTH_MAX_RETRIES * HEALTH_RETRY_DELAY))s")
    done

    if [ "${#failures[@]}" -gt 0 ]; then
        local body
        body=$(printf '%s\n\n' "${failures[@]}")
        send_notification "SnapRAID UNPAUSE FAIL" "One or more containers paused for SnapRAID sync on $HOST_LABEL did not resume to a healthy state:

$body"
    fi
}

cleanup() {
    rm -f "$LOCK_FILE"
    if [ "${#paused_list[@]}" -gt 0 ]; then
        log_message "Unpausing and verifying containers..."
        verify_and_unpause
    fi
    if [ "$kuma_maintenance_active" -eq 1 ]; then
        kuma_maintenance_exit
    fi
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
        log_message "Another snapraid-sync run is in progress (PID $existing_pid). Exiting."
        exit 1
    fi
    log_message "Stale lock file found; removing."
    rm -f "$LOCK_FILE"
fi

if [ -e "$SCRUB_LOCK_FILE" ]; then
    scrub_pid=$(cat "$SCRUB_LOCK_FILE" 2>/dev/null)
    if [ -n "$scrub_pid" ] && [ -d "/proc/$scrub_pid" ]; then
        log_message "Scrub is currently running (PID $scrub_pid). Deferring sync."
        exit 0
    fi
fi

echo $$ > "$LOCK_FILE"

log_message "Starting SnapRAID Sync on $HOST_LABEL..."

# 1. Pre-check: parity disk present and not (nearly) full
if [ ! -d "$PARITY_MOUNT" ]; then
    send_notification "SnapRAID SYNC FAIL" "Parity mount $PARITY_MOUNT not found on $HOST_LABEL."
    exit 1
fi

usage_percent=$(df --output=pcent "$PARITY_MOUNT" 2>/dev/null | tail -1 | tr -d '% ')
if [[ "$usage_percent" =~ ^[0-9]+$ ]]; then
    if [ "$usage_percent" -ge "$PARITY_WARN_PERCENT" ]; then
        send_notification "SnapRAID WARNING" "Parity drive is at $usage_percent% capacity on $HOST_LABEL."
    fi
else
    log_message "WARN: Could not parse disk usage for $PARITY_MOUNT (got '$usage_percent')."
fi

# 2. Let in-flight *arr imports finish. Runs BEFORE the Kuma window so the
#    window still starts right at the real pause boundary.
if [ "${#ARR_INSTANCES[@]}" -gt 0 ]; then
    log_message "Checking *arr apps for active imports before pausing..."
    wait_for_arr_quiet
fi

# 3. Kuma maintenance (before pausing, so there's no alert gap)
kuma_maintenance_enter

# 4. Pause write-churn containers
if [ "${#PAUSE_CONTAINERS[@]}" -gt 0 ]; then
    log_message "Pausing active write containers to prevent file churn..."
    running=$(docker_host docker ps --format '{{.Names}}')
    for c in "${PAUSE_CONTAINERS[@]}"; do
        grep -qx "$c" <<< "$running" || continue
        [ "$(docker_paused "$c")" = "false" ] || continue
        if docker_host docker pause "$c" >/dev/null 2>&1; then
            if [ "$(docker_paused "$c")" = "true" ]; then
                paused_list+=("$c")
                log_message "Paused container: $c"
            else
                log_message "WARN: 'docker pause' for $c reported success but it is not paused; not tracking it."
            fi
        else
            log_message "WARN: Failed to pause container: $c"
        fi
    done
fi

# 5. Touch (gives zero-subsecond timestamps a sub-second value so SnapRAID
#    can detect moves reliably)
log_message "Running snapraid touch..."
snapraid touch 2>&1 | tee -a "$LOG_FILE"
touch_status=${PIPESTATUS[0]}
if [ "$touch_status" -ne 0 ]; then
    log_message "WARN: snapraid touch exited with status $touch_status (continuing)."
fi

# 6. Sync
log_message "Running snapraid sync..."
sync_start_epoch=$(date +%s)
sync_tmp=$(mktemp /tmp/snapraid-sync-output.XXXXXX)
snapraid sync 2>&1 | tee -a "$LOG_FILE" > "$sync_tmp"
sync_status=${PIPESTATUS[0]}
sync_elapsed=$(( $(date +%s) - sync_start_epoch ))

# Progress lines ("99%, 1112318 MB, 98 MB/s, ...") are \r-separated. Match
# ", <digits> MB," (comma both sides) so the "98 MB/s" field isn't picked up.
moved_mb=$(tr '\r' '\n' < "$sync_tmp" | grep -oE ', [0-9]+ MB,' | grep -oE '[0-9]+' | tail -1)
rm -f "$sync_tmp"
if [ -n "$moved_mb" ] && [ "$sync_elapsed" -gt 0 ]; then
    log_message "Sync data volume: ~${moved_mb} MB moved in ${sync_elapsed}s (~$(( moved_mb / sync_elapsed )) MB/s wall-clock avg)."
fi

if [ "$sync_status" -ne 0 ]; then
    diff_output=$(snapraid diff 2>&1 | tail -n 30)
    send_notification "SnapRAID SYNC FAIL" "Sync failed on $HOST_LABEL (exit $sync_status). Likely file churn or deletion threshold.

--- snapraid diff (tail) ---
$diff_output"
    exit 1
fi

log_message "Sync Complete Successfully."
exit 0
