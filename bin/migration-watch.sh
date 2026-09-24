#!/usr/bin/env bash
# ===============================================================
# Script:       migration-watch.sh
# Version:      1.0.0
# Date:         2026-09-24
# License:      MIT
# Description:  Generic progress watcher for long-running array
#               maintenance steps (rsync copy onto a new disk, snapraid
#               sync/scrub, mergerfs.balance). Polls a log file (or, in
#               'balance' mode, live df output) every POLL_INTERVAL
#               seconds, extracts a completion percentage, and sends a
#               notification each time a new 10% decile is crossed.
#               Interim deciles: email only. Completion (100% / done
#               marker seen): email + ntfy.
#
#               Designed to run inside tmux alongside the real command,
#               e.g.:
#                 tmux new-session -d -s parity-copy \
#                   "rsync -avh --info=progress2 SRC DST 2>&1 | tee LOG; \
#                    echo MIGRATION_STEP_DONE exit=$? >> LOG"
#                 tmux new-session -d -s parity-copy-watch \
#                   "/usr/local/bin/migration-watch.sh --mode rsync \
#                    --label 'Phase 2: parity file copy' --log LOG"
#
#               Notification defaults come from
#               /etc/snapraid-toolkit.conf; every one can be overridden
#               on the command line. An empty email or ntfy setting
#               disables that channel.
# ===============================================================

set -uo pipefail

NTFY_URL=""; NTFY_TOKEN=""; EMAIL_TO=""; MSMTP_ACCOUNT="default"
CONF="${SNAPRAID_TOOLKIT_CONF:-/etc/snapraid-toolkit.conf}"
# shellcheck disable=SC1090
[ -f "$CONF" ] && source "$CONF"

MODE=""
LABEL=""
LOG=""
DONE_MARKER="MIGRATION_STEP_DONE"
POLL_INTERVAL=60
EMAIL_ACCOUNT="$MSMTP_ACCOUNT"
BALANCE_MOUNTS=""
BALANCE_TARGET_SPREAD="2.0"

usage() {
    cat >&2 <<EOF
Usage: $0 --mode {rsync|snapraid|balance|waitonly} --label "text" --log /path/to/log [options]

Required:
  --mode MODE            rsync | snapraid | balance | waitonly
                         waitonly: no progress parsing at all (e.g. sha256sum,
                         which has no percentage/ETA output) -- just polls for
                         the done marker and fires the completion notification.
  --label TEXT           Human-readable step name for notifications
  --log PATH             Log file the real command is tee'ing into

Options:
  --done-marker STR      Sentinel line marking completion (default: $DONE_MARKER)
  --poll-interval SEC    Poll interval in seconds (default: $POLL_INTERVAL)
  --email-to ADDR        (default: $EMAIL_TO)
  --email-account NAME   msmtp account name (default: $EMAIL_ACCOUNT)
  --ntfy-url URL         (default: $NTFY_URL)
  --ntfy-token TOKEN     (default: NTFY_TOKEN from the config file)
  --balance-mounts LIST  Comma-separated mountpoints, required for --mode balance
                         e.g. /mnt/disk1,/mnt/disk2,/mnt/disk3,/mnt/disk4
  --balance-target N     Target free-space spread in percentage points,
                         matches mergerfs.balance's -p value (default: $BALANCE_TARGET_SPREAD)
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode) MODE="$2"; shift 2 ;;
        --label) LABEL="$2"; shift 2 ;;
        --log) LOG="$2"; shift 2 ;;
        --done-marker) DONE_MARKER="$2"; shift 2 ;;
        --poll-interval) POLL_INTERVAL="$2"; shift 2 ;;
        --email-to) EMAIL_TO="$2"; shift 2 ;;
        --email-account) EMAIL_ACCOUNT="$2"; shift 2 ;;
        --ntfy-url) NTFY_URL="$2"; shift 2 ;;
        --ntfy-token) NTFY_TOKEN="$2"; shift 2 ;;
        --balance-mounts) BALANCE_MOUNTS="$2"; shift 2 ;;
        --balance-target) BALANCE_TARGET_SPREAD="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done

[[ -z "$MODE" || -z "$LABEL" || -z "$LOG" ]] && usage
if [[ "$MODE" == "balance" && -z "$BALANCE_MOUNTS" ]]; then
    echo "--balance-mounts is required for --mode balance" >&2
    exit 1
fi

send_email() {
    local subject="$1" body="$2"
    [[ -n "$EMAIL_TO" ]] || return 0
    printf 'Subject: %s\n\n%s\n' "$subject" "$body" | msmtp -a "$EMAIL_ACCOUNT" "$EMAIL_TO"
}

send_ntfy() {
    local subject="$1" body="$2" priority="${3:-3}" tags="${4:-hourglass}"
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

notify_decile() {
    local pct="$1"
    local eta_line=""
    local completion
    completion=$(estimate_completion)
    [[ -n "$completion" ]] && eta_line="
Estimated completion: $completion"
    local subject="Migration progress: $LABEL — ${pct}%"
    local body="$LABEL is ${pct}% complete.
${eta_line}

Log: $LOG
Host: $(hostname)
Time: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    send_email "$subject" "$body"
    send_ntfy "$subject" "$body" "2" "hourglass_flowing_sand"
}

notify_done() {
    local exit_code="$1"
    local status_word="completed"
    local priority="2"
    local tags="white_check_mark"
    if [[ "$exit_code" != "0" ]]; then
        status_word="FAILED (exit $exit_code)"
        priority="5"
        tags="rotating_light"
    fi
    local subject="Migration step $status_word: $LABEL"
    local body="$LABEL has finished — $status_word.

Log: $LOG
Host: $(hostname)
Time: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    send_email "$subject" "$body"
    send_ntfy "$subject" "$body" "$priority" "$tags"
}

# Extracts the last matching progress percentage from a log, normalizing
# \r-delimited live-redraw lines (rsync/snapraid both use \r, not \n, for
# in-place progress updates) into real lines first so grep can see them.
extract_pct() {
    local pattern="$1"
    [[ -f "$LOG" ]] || { echo ""; return; }
    tr '\r' '\n' < "$LOG" | grep -oE "$pattern" | tail -n1 | grep -oE '[0-9]{1,3}' | head -n1
}

# Converts the tool's own remaining-time estimate into an absolute wall-clock
# completion time. snapraid prints "H:MM ETA" (e.g. "9:16 ETA" == 9h16m left,
# confirmed against real multi-hour scrub output -- NOT M:SS,
# despite the single leading digit looking like minutes at a glance). rsync's
# --info=progress2 prints a trailing H:MM:SS field with no "ETA" label at all.
# Returns empty string (silently omitted from the email) if no ETA is found
# yet, e.g. very early in a run before the tool has enough data to estimate.
estimate_completion() {
    [[ -f "$LOG" ]] || { echo ""; return; }
    local h="" m="" s="0"
    case "$MODE" in
        snapraid)
            local eta
            eta=$(tr '\r' '\n' < "$LOG" | grep -oE '[0-9]+:[0-9]{2} ETA' | tail -n1)
            [[ -z "$eta" ]] && { echo ""; return; }
            h="${eta%%:*}"
            m="${eta#*:}"; m="${m%% ETA}"
            ;;
        rsync)
            local eta
            eta=$(tr '\r' '\n' < "$LOG" | grep -oE '[0-9]+:[0-9]{2}:[0-9]{2}' | tail -n1)
            [[ -z "$eta" ]] && { echo ""; return; }
            h="${eta%%:*}"
            local rest="${eta#*:}"
            m="${rest%%:*}"
            s="${rest#*:}"
            ;;
        *)
            echo ""; return ;;
    esac
    [[ -z "$h" || -z "$m" ]] && { echo ""; return; }
    local total_seconds=$(( 10#$h * 3600 + 10#$m * 60 + 10#$s ))
    date -d "+${total_seconds} seconds" '+%Y-%m-%d %H:%M %Z' 2>/dev/null
}

# WATCH_START_OFFSET (set just before the main loop) is the LOG file's byte
# size at the moment this watcher started. Long-running migration logs get
# reused/appended-to across multiple restarts of the underlying job, and an
# earlier run's DONE_MARKER can still be sitting in the file from a prior
# (possibly abnormal) exit -- a plain whole-file grep would find that stale
# marker immediately and report false completion. Only scanning bytes
# written after this watcher's own start avoids that (a stale marker from
# an earlier killed run caused exactly this false positive in practice).
#
# BALANCE_DONE_PATTERN (mode=balance only): mergerfs.balance itself prints
# "Branches within X% range:" once, unconditionally, right after its main
# loop exits for ANY internal reason (target reached, ran out of files,
# source==target edge case) -- but it is NEVER printed if the process is
# killed by a signal (e.g. systemd sending SIGTERM on `systemctl stop` for
# a planned reconfig, or an external kill). That makes it a reliable
# real-completion signal on its own. Balance mode uses this instead of an
# injected DONE_MARKER, because when this ran under systemd, `systemctl
# stop` for a routine reconfig was recorded by systemd as
# SERVICE_RESULT=success (an admin-requested stop, not a failure) --
# indistinguishable from genuine completion by that signal alone, which
# caused real false-positive alerts (both false "completed" and false
# "FAILED") before this approach was adopted.
BALANCE_DONE_PATTERN="Branches within"

check_done_marker() {
    [[ -f "$LOG" ]] || return 1
    if [[ "$MODE" == "balance" ]]; then
        tail -c "+$((WATCH_START_OFFSET + 1))" "$LOG" 2>/dev/null | grep -q "$BALANCE_DONE_PATTERN"
    else
        tail -c "+$((WATCH_START_OFFSET + 1))" "$LOG" 2>/dev/null | grep -q "$DONE_MARKER"
    fi
}

get_done_exit_code() {
    if [[ "$MODE" == "balance" ]]; then
        # mergerfs.balance always sys.exit(0)s on any internal (non-signal)
        # exit path -- the pattern's mere presence already means "finished
        # normally," so there's no separate numeric code to extract.
        echo "0"
        return
    fi
    tail -c "+$((WATCH_START_OFFSET + 1))" "$LOG" 2>/dev/null | tr '\r' '\n' | grep "$DONE_MARKER" | tail -n1 | grep -oE 'exit=[0-9]+' | cut -d= -f2
}

# --- Balance mode: no aggregate % in mergerfs.balance's own output, so
# progress is derived independently from how much the free-space spread
# across branches has narrowed toward the target range since this watcher
# started. ---
balance_free_pct() {
    local mount="$1"
    df --output=avail,size "$mount" 2>/dev/null | tail -n1 | \
        awk '{ if ($2 > 0) printf "%.4f", ($1/$2)*100; else print "" }'
}

balance_spread() {
    local mounts
    IFS=',' read -r -a mounts <<< "$BALANCE_MOUNTS"
    local min="" max=""
    for m in "${mounts[@]}"; do
        local p
        p=$(balance_free_pct "$m")
        [[ -z "$p" ]] && continue
        if [[ -z "$min" ]] || (( $(echo "$p < $min" | bc -l) )); then min="$p"; fi
        if [[ -z "$max" ]] || (( $(echo "$p > $max" | bc -l) )); then max="$p"; fi
    done
    [[ -z "$min" || -z "$max" ]] && { echo ""; return; }
    echo "$max - $min" | bc -l
}

WATCH_START_OFFSET=$(stat -c%s "$LOG" 2>/dev/null || echo 0)

echo "[migration-watch] mode=$MODE label='$LABEL' log=$LOG poll=${POLL_INTERVAL}s"
echo "[migration-watch] watching for new content past byte offset $WATCH_START_OFFSET (ignoring any pre-existing DONE_MARKER)"

last_decile=0
initial_spread=""

if [[ "$MODE" == "balance" ]]; then
    initial_spread=$(balance_spread)
    echo "[migration-watch] initial free-space spread: ${initial_spread}pp, target: ${BALANCE_TARGET_SPREAD}pp"
fi

while true; do
    if check_done_marker; then
        exit_code=$(get_done_exit_code)
        exit_code="${exit_code:-unknown}"
        echo "[migration-watch] done marker seen, exit=$exit_code"
        notify_done "$exit_code"
        break
    fi

    pct=""
    case "$MODE" in
        rsync)
            pct=$(extract_pct '[0-9]{1,3}%')
            ;;
        snapraid)
            pct=$(extract_pct '[0-9]{1,3}%, [0-9]+ MB')
            ;;
        balance)
            if [[ -n "$initial_spread" ]]; then
                current_spread=$(balance_spread)
                if [[ -n "$current_spread" ]]; then
                    denom=$(echo "$initial_spread - $BALANCE_TARGET_SPREAD" | bc -l)
                    if (( $(echo "$denom > 0" | bc -l) )); then
                        raw_pct=$(echo "scale=2; 100 * ($initial_spread - $current_spread) / $denom" | bc -l)
                        pct=$(printf '%.0f' "$raw_pct")
                        [[ "$pct" -lt 0 ]] && pct=0
                        [[ "$pct" -gt 99 ]] && pct=99  # 100 is reserved for the done marker
                    fi
                fi
            fi
            ;;
        waitonly)
            : # no progress parsing -- pct stays empty, only the done-marker check above matters
            ;;
    esac

    if [[ -n "$pct" && "$pct" =~ ^[0-9]+$ ]]; then
        decile=$(( (pct / 10) * 10 ))
        if [[ "$decile" -gt "$last_decile" && "$decile" -lt 100 ]]; then
            echo "[migration-watch] crossed ${decile}% (raw ${pct}%)"
            notify_decile "$decile"
            last_decile=$decile
        fi
    fi

    sleep "$POLL_INTERVAL"
done

echo "[migration-watch] exiting."
