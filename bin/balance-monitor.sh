#!/usr/bin/env bash
# ===============================================================
# Script:       balance-monitor.sh
# Version:      1.0.0
# Date:         2026-09-24
# License:      MIT
# Description:  Live terminal dashboard for watching mergerfs.balance
#               progress (e.g. after adding a new disk to the pool).
#               Auto-discovers the mergerfs pool's branches
#               via mergerfs.ctl, then every POLL_INTERVAL seconds
#               redraws a df-based utilization table per branch plus
#               the current free-space spread, percent progress toward
#               the target spread (default 2.0, matching
#               mergerfs.balance's own -p default), and a linearly
#               extrapolated ETA once enough runway has passed to make
#               that extrapolation meaningful.
#
#               Also pushes an ntfy progress update every
#               NTFY_INTERVAL seconds (default 20 min) so progress can
#               be checked without keeping the terminal open --
#               separate from migration-watch.sh's own decile-based
#               email/ntfy alerts and completion notification, which
#               this script does not duplicate (no "done" push here;
#               migration-watch.sh --mode balance already owns that).
#
#               This is a read-only viewer -- it does not start,
#               stop, or otherwise control the mergerfs.balance job.
#               Run it in its own tmux pane alongside the real
#               mergerfs.balance process and the migration-watch.sh
#               notifier.
#
#               Requires mergerfs-tools (mergerfs.ctl) for branch
#               auto-discovery, plus bc and numfmt. ntfy defaults come
#               from /etc/snapraid-toolkit.conf; empty NTFY_URL disables.
# ===============================================================

set -uo pipefail

NTFY_URL=""; NTFY_TOKEN=""
CONF="${SNAPRAID_TOOLKIT_CONF:-/etc/snapraid-toolkit.conf}"
# shellcheck disable=SC1090
[ -f "$CONF" ] && source "$CONF"

POOL="/mnt/storage"
TARGET_SPREAD="2.0"
POLL_INTERVAL=30
MIN_RUNWAY_SECONDS=180
MOUNTS=""
NTFY_INTERVAL=1200

usage() {
    cat >&2 <<EOF
Usage: $0 [options]

Options:
  --pool PATH            mergerfs pool mount to query branches from (default: $POOL)
  --mounts LIST           Comma-separated branch list, skips auto-discovery
  --target N              Target free-space spread in percentage points (default: $TARGET_SPREAD)
  --poll-interval SEC      Refresh interval in seconds (default: $POLL_INTERVAL)
  --ntfy-interval SEC      How often to push an ntfy progress update, 0 disables (default: $NTFY_INTERVAL)
  --ntfy-url URL           (default: $NTFY_URL)
  --ntfy-token TOKEN       (default: NTFY_TOKEN from the config file)
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pool) POOL="$2"; shift 2 ;;
        --mounts) MOUNTS="$2"; shift 2 ;;
        --target) TARGET_SPREAD="$2"; shift 2 ;;
        --poll-interval) POLL_INTERVAL="$2"; shift 2 ;;
        --ntfy-interval) NTFY_INTERVAL="$2"; shift 2 ;;
        --ntfy-url) NTFY_URL="$2"; shift 2 ;;
        --ntfy-token) NTFY_TOKEN="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done

if [[ -z "$MOUNTS" ]]; then
    MOUNTS=$(mergerfs.ctl -m "$POOL" get srcmounts 2>/dev/null | tail -n1 | sed 's/^.*srcmounts: *//' | tr ':' ',')
    if [[ -z "$MOUNTS" ]]; then
        echo "Could not auto-discover branches from $POOL via mergerfs.ctl -- pass --mounts explicitly" >&2
        exit 1
    fi
fi

IFS=',' read -r -a BRANCHES <<< "$MOUNTS"

branch_stats() {
    local mount="$1"
    df --output=size,used,avail,pcent "$mount" 2>/dev/null | tail -n1
}

free_pct() {
    local mount="$1"
    df --output=avail,size "$mount" 2>/dev/null | tail -n1 | \
        awk '{ if ($2 > 0) printf "%.4f", ($1/$2)*100; else print "" }'
}

spread() {
    local min="" max=""
    for m in "${BRANCHES[@]}"; do
        local p
        p=$(free_pct "$m")
        [[ -z "$p" ]] && continue
        if [[ -z "$min" ]] || (( $(echo "$p < $min" | bc -l) )); then min="$p"; fi
        if [[ -z "$max" ]] || (( $(echo "$p > $max" | bc -l) )); then max="$p"; fi
    done
    [[ -z "$min" || -z "$max" ]] && { echo ""; return; }
    echo "$max - $min" | bc -l
}

send_ntfy() {
    # Priority 2 (low) -- quiet but not fully silent, since this is a
    # periodic progress ping, not an actionable event. Completion/failure
    # alerts remain migration-watch.sh's job, at its normal priority.
    local subject="$1" body="$2"
    [[ -n "$NTFY_URL" ]] || return 0
    local auth=()
    [[ -n "$NTFY_TOKEN" ]] && auth=(-H "Authorization: Bearer $NTFY_TOKEN")
    curl -s -o /dev/null \
        -H "Title: $subject" \
        -H "Priority: 2" \
        -H "Tags: bar_chart" \
        "${auth[@]}" \
        -d "$body" \
        "$NTFY_URL"
}

start_time=$(date +%s)
initial_spread=$(spread)
last_ntfy_time=$start_time

if [[ -z "$initial_spread" ]]; then
    echo "Could not compute initial spread across branches -- aborting" >&2
    exit 1
fi

while true; do
    now=$(date +%s)
    elapsed=$(( now - start_time ))
    current_spread=$(spread)

    clear
    echo "=== mergerfs balance monitor: $POOL ==="
    echo "Time: $(date '+%Y-%m-%d %H:%M:%S %Z')   Elapsed: $(( elapsed / 60 ))m $(( elapsed % 60 ))s"
    echo
    printf "%-16s %8s %8s %8s %7s %7s\n" "BRANCH" "SIZE" "USED" "AVAIL" "USE%" "FREE%"
    for m in "${BRANCHES[@]}"; do
        stats=$(branch_stats "$m")
        if [[ -z "$stats" ]]; then
            printf "%-16s %s\n" "$m" "(unreadable)"
            continue
        fi
        size=$(echo "$stats" | awk '{print $1}')
        used=$(echo "$stats" | awk '{print $2}')
        avail=$(echo "$stats" | awk '{print $3}')
        pcent=$(echo "$stats" | awk '{print $4}')
        fpct=$(free_pct "$m")
        printf "%-16s %8s %8s %8s %7s %6.2f%%\n" \
            "$m" "$(numfmt --to=iec --suffix=B $((size*1024)) 2>/dev/null || echo "${size}K")" \
            "$(numfmt --to=iec --suffix=B $((used*1024)) 2>/dev/null || echo "${used}K")" \
            "$(numfmt --to=iec --suffix=B $((avail*1024)) 2>/dev/null || echo "${avail}K")" \
            "$pcent" "$fpct"
    done
    echo

    if [[ -z "$current_spread" ]]; then
        echo "Could not read current spread this cycle -- retrying next poll."
        sleep "$POLL_INTERVAL"
        continue
    fi

    denom=$(echo "$initial_spread - $TARGET_SPREAD" | bc -l)
    if (( $(echo "$denom > 0" | bc -l) )); then
        raw_pct=$(echo "scale=2; 100 * ($initial_spread - $current_spread) / $denom" | bc -l)
    else
        raw_pct="100"
    fi
    pct=$(printf '%.0f' "$raw_pct")
    [[ "$pct" -lt 0 ]] && pct=0
    [[ "$pct" -gt 100 ]] && pct=100

    spread_line=$(printf "Free-space spread: %.2fpp (started at %.2fpp, target <= %.2fpp)" \
        "$current_spread" "$initial_spread" "$TARGET_SPREAD")
    progress_line=$(printf "Progress toward target: %d%%" "$pct")
    echo "$spread_line"
    echo "$progress_line"

    eta_line=""
    if (( $(echo "$current_spread <= $TARGET_SPREAD" | bc -l) )); then
        eta_line="Target spread reached -- balance should be finishing up (mergerfs.balance exits on its own)."
    elif [[ "$elapsed" -lt "$MIN_RUNWAY_SECONDS" || "$pct" -le 0 ]]; then
        eta_line="ETA: (gathering data, need a few more minutes before extrapolating)"
    else
        rate_pct_per_sec=$(echo "scale=6; $pct / $elapsed" | bc -l)
        remaining_pct=$(echo "100 - $pct" | bc -l)
        remaining_seconds=$(echo "$remaining_pct / $rate_pct_per_sec" | bc -l 2>/dev/null | cut -d. -f1)
        if [[ -n "$remaining_seconds" && "$remaining_seconds" =~ ^[0-9]+$ ]]; then
            eta=$(date -d "+${remaining_seconds} seconds" '+%Y-%m-%d %H:%M %Z' 2>/dev/null)
            eta_line=$(printf "ETA (linear extrapolation from progress so far): %s (~%dh %dm remaining)" \
                "$eta" "$(( remaining_seconds / 3600 ))" "$(( (remaining_seconds % 3600) / 60 ))")
        else
            eta_line="ETA: (could not extrapolate this cycle)"
        fi
    fi
    echo "$eta_line"

    if [[ "$NTFY_INTERVAL" -gt 0 ]] && (( now - last_ntfy_time >= NTFY_INTERVAL )); then
        send_ntfy "Balance progress: ${pct}%" \
            "$spread_line
$progress_line
$eta_line

Host: $(hostname)
Time: $(date '+%Y-%m-%d %H:%M:%S %Z')"
        last_ntfy_time=$now
    fi

    echo
    echo "Ctrl-C to exit. Refreshing every ${POLL_INTERVAL}s. ntfy push every $(( NTFY_INTERVAL / 60 ))m."
    sleep "$POLL_INTERVAL"
done
