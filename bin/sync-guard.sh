#!/usr/bin/env bash
# ===============================================================
# Script:   sync-guard.sh
# Version:  1.1.0
# Date:     2026-09-24
# v1.1.0: alert titles use $LABEL (default unchanged) instead of a
#         hardcoded job name.
# License:  MIT
# ===============================================================
# Combined exit + stall guard for a manually-started long-running command
# (e.g. `snapraid --force-full sync | tee LOG`) running as a FOREGROUND job
# in an interactive tmux pane (TARGET, default session 0). This matters:
# pane_dead never becomes 1 when a foreground job in an interactive shell
# exits (crashes or completes) -- the shell just reclaims the pane and sits
# at a prompt. Detection is instead based on pane_current_command changing
# away from EXPECTED_CMD. (A test against a wrapped, non-interactive
# `tmux new-session -d -s x "cmd"` misleadingly validates a pane_dead-based
# approach that does not apply to interactive panes.)
#
# On detecting the pane command change: since there's no reliable way to
# read the real shell exit status without racily typing into the pane
# (which could pick up a stale $?/$status if the user runs anything else
# first), classification instead scans the tail of the log for snapraid's
# own WARNING!/ERROR!/DANGER!/Aborting output. Ambiguous or crash cases are
# deliberately treated as failure (exit=1) rather than silently assumed
# successful -- a false FAILED alert on a real success is far cheaper than
# silence on a real crash for an unattended ~24h job.
#
# Writes MIGRATION_STEP_DONE into the log on completion/crash, which
# migration-watch.sh picks up via its own done-marker logic and sends the
# completion/FAILED notification.
#
# Also independently alerts (and later un-alerts) on log staleness while
# EXPECTED_CMD is still the active pane command, since migration-watch.sh
# has no freeze/stall detection at all.
#
# All settings are environment variables (see systemd/examples/). Email and
# ntfy defaults come from /etc/snapraid-toolkit.conf; empty = disabled.
set -uo pipefail

# Snapshot any env overrides before the config file is sourced.
_ENV_NTFY_URL="${NTFY_URL-}"; _ENV_NTFY_TOKEN="${NTFY_TOKEN-}"; _ENV_EMAIL_TO="${EMAIL_TO-}"
NTFY_URL=""; NTFY_TOKEN=""; EMAIL_TO=""; MSMTP_ACCOUNT="default"
CONF="${SNAPRAID_TOOLKIT_CONF:-/etc/snapraid-toolkit.conf}"
# shellcheck disable=SC1090
[ -f "$CONF" ] && source "$CONF"
NTFY_URL="${_ENV_NTFY_URL:-$NTFY_URL}"
NTFY_TOKEN="${_ENV_NTFY_TOKEN:-$NTFY_TOKEN}"
EMAIL_TO="${_ENV_EMAIL_TO:-$EMAIL_TO}"

TARGET="${TARGET:-0}"
EXPECTED_CMD="${EXPECTED_CMD:-snapraid}"
LOG="${LOG:-/var/log/snapraid-manual-force-sync.log}"
LABEL="${LABEL:-Manual --force-full sync}"
POLL_INTERVAL="${POLL_INTERVAL:-60}"
STALL_THRESHOLD="${STALL_THRESHOLD:-1800}"
DONE_MARKER="MIGRATION_STEP_DONE"
EMAIL_ACCOUNT="${EMAIL_ACCOUNT:-$MSMTP_ACCOUNT}"

send_email() {
    local subject="$1"
    local body="$2"
    [[ -n "$EMAIL_TO" ]] || return 0
    printf 'Subject: %s\n\n%s\n' "$subject" "$body" | msmtp -a "$EMAIL_ACCOUNT" "$EMAIL_TO"
}

send_ntfy() {
    local subject="$1"
    local body="$2"
    local priority="$3"
    local tags="$4"
    [[ -n "$NTFY_URL" ]] || return 0
    local auth=()
    [[ -n "$NTFY_TOKEN" ]] && auth=(-H "Authorization: Bearer $NTFY_TOKEN")
    curl -s -o /dev/null \
        -H "Title: $subject" \
        -H "Priority: $priority" \
        -H "Tags: $tags" \
        "${auth[@]}" \
        -d "$body" \
        "$NTFY_URL"
}

append_marker() {
    local code="$1"
    echo "$DONE_MARKER exit=$code" >> "$LOG"
    echo "[sync-guard] wrote $DONE_MARKER exit=$code"
}

already_done() {
    [[ -f "$LOG" ]] || return 1
    tail -c "+$((WATCH_START_OFFSET + 1))" "$LOG" 2>/dev/null | grep -q "$DONE_MARKER"
}

WATCH_START_OFFSET=$(stat -c%s "$LOG" 2>/dev/null || echo 0)
stall_alerted=0

while true; do
    if already_done; then
        echo "[sync-guard] done marker already present, exiting"
        break
    fi

    pane_info=$(tmux list-panes -t "$TARGET" -F '#{pane_dead} #{pane_current_command}' 2>/dev/null)
    if [[ -z "$pane_info" ]]; then
        echo "[sync-guard] tmux session/pane '$TARGET' not found -- treating as crash"
        append_marker "unknown"
        subject="Migration step CRASHED: $LABEL"
        body="tmux session '$TARGET' is gone entirely (not just the job -- the whole session vanished).

Log: $LOG
Host: $(hostname)
Time: $(date '+%Y-%m-%d %H:%M:%S %Z')

This needs manual attention -- check whether the tmux server itself died."
        send_email "$subject" "$body"
        send_ntfy "$subject" "$body" "5" "rotating_light"
        break
    fi

    pane_dead="${pane_info%% *}"
    pane_cmd="${pane_info#* }"

    if [[ "$pane_dead" == "1" ]]; then
        status=$(tmux list-panes -t "$TARGET" -F '#{pane_dead_status}' 2>/dev/null)
        append_marker "${status:-unknown}"
        break
    fi

    if [[ "$pane_cmd" != "$EXPECTED_CMD" ]]; then
        echo "[sync-guard] pane command briefly showed '$pane_cmd' instead of '$EXPECTED_CMD' -- debounce recheck in 5s"
        sleep 5
        recheck=$(tmux list-panes -t "$TARGET" -F '#{pane_current_command}' 2>/dev/null)
        if [[ "$recheck" == "$EXPECTED_CMD" ]]; then
            echo "[sync-guard] false alarm, back to $EXPECTED_CMD -- ignoring transient blip (e.g. suspend/resume, terminal redraw)"
            sleep "$POLL_INTERVAL"
            continue
        fi
        echo "[sync-guard] confirmed: pane command is now '$recheck', not $EXPECTED_CMD -- job ended"
        code=0
        if [[ -f "$LOG" ]] && tail -c 200000 "$LOG" | tr '\r' '\n' | grep -qE 'WARNING!|ERROR!|DANGER!|Aborting'; then
            code=1
        fi
        append_marker "$code"
        break
    fi

    if [[ -f "$LOG" ]]; then
        now=$(date +%s)
        mtime=$(stat -c%Y "$LOG")
        idle=$(( now - mtime ))
        if (( idle >= STALL_THRESHOLD )); then
            if (( stall_alerted == 0 )); then
                subject="Migration step possibly STALLED: $LABEL"
                body="No new output in the sync log for $((idle/60)) minutes (threshold: $((STALL_THRESHOLD/60))m), but the process is still running.

Log: $LOG
Host: $(hostname)
Time: $(date '+%Y-%m-%d %H:%M:%S %Z')

Check tmux session $TARGET on $(hostname)."
                send_email "$subject" "$body"
                send_ntfy "$subject" "$body" "4" "warning"
                echo "[sync-guard] stall alert sent (idle ${idle}s)"
                stall_alerted=1
            fi
        else
            if (( stall_alerted == 1 )); then
                subject="Migration step resumed: $LABEL"
                body="New output detected in the sync log again after a stall.

Log: $LOG
Host: $(hostname)
Time: $(date '+%Y-%m-%d %H:%M:%S %Z')"
                send_email "$subject" "$body"
                send_ntfy "$subject" "$body" "3" "information_source"
                echo "[sync-guard] resumed notice sent"
                stall_alerted=0
            fi
        fi
    fi

    sleep "$POLL_INTERVAL"
done
