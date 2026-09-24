# balance-monitor.sh

A live terminal dashboard for `mergerfs.balance`: usage per disk, how far the free-space spread has closed, and an estimated finish time. It also sends an occasional ntfy progress ping.

It is **read-only**: it never starts, stops or controls the balance. Run it in its own tmux pane next to the real `mergerfs.balance` process.

**Requires:** `mergerfs-tools` (for `mergerfs.ctl` branch discovery), `bc`, `numfmt`.

## Usage

```bash
balance-monitor.sh                         # pool at /mnt/storage, branches auto-discovered
balance-monitor.sh --pool /mnt/pool --target 1.5
balance-monitor.sh --mounts /mnt/data1,/mnt/data2,/mnt/data3
```

## Options

| Option | Default | Meaning |
|---|---|---|
| `--pool PATH` | `/mnt/storage` | mergerfs mount; its branches are discovered with `mergerfs.ctl` |
| `--mounts LIST` | *(auto)* | Comma-separated branch list; skips auto-discovery |
| `--target N` | `2.0` | Target spread in percentage points; match `mergerfs.balance -p` |
| `--poll-interval SEC` | `30` | Screen refresh interval |
| `--ntfy-interval SEC` | `1200` | ntfy progress ping interval (20 min); `0` disables |
| `--ntfy-url URL` / `--ntfy-token TOKEN` | from config | |

## How progress is measured

`mergerfs.balance` doesn't report a percentage itself. This script measures the **free-space spread**: the gap between the emptiest and fullest branch, as a percentage of each disk's size. It records the spread when it starts, then reports how much of the distance to `--target` has been closed. Once there's at least 3 minutes of data, it projects a finish time from the rate so far.

## Example screen

```
=== mergerfs balance monitor: /mnt/storage ===
Time: 2026-09-24 14:20:00 MDT   Elapsed: 42m 10s

BRANCH               SIZE     USED    AVAIL    USE%   FREE%
/mnt/data1           7.3T     5.1T     2.2T     70%  30.12%
/mnt/data2           7.3T     5.0T     2.3T     69%  31.40%
/mnt/data3           7.3T     4.9T     2.4T     67%  32.88%
/mnt/data4           7.3T     3.6T     3.7T     50%  50.03%

Free-space spread: 19.91pp (started at 35.20pp, target <= 2.00pp)
Progress toward target: 46%
ETA (linear extrapolation from progress so far): 2026-09-24 15:09 MDT (~0h 49m remaining)

Ctrl-C to exit. Refreshing every 30s. ntfy push every 20m.
```

The ETA assumes a steady rate. Balance speed depends on file sizes, so treat it as a rough guide.

## Notifications

Every `--ntfy-interval` seconds it sends a low-priority (2) ntfy message titled `Balance progress: NN%`, containing the spread, progress and ETA lines. There's no "finished" notification from this script. For that, run [migration-watch](migration-watch.md) with `--mode balance`.
