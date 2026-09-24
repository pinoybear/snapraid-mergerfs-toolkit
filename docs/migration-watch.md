# migration-watch.sh

Progress notifications for any long job that writes to a log: a notification at every 10%, with an estimated finish time, and one more when the job completes or fails.

Built for multi-hour array work, such as copying a disk with rsync, a `snapraid sync` or `scrub` after adding a disk, or `mergerfs.balance`, where you want updates on your phone without watching a terminal.

**Runs:** manually, in its own tmux session or as a service (see [`systemd/examples/`](../systemd/examples/)).

## How it works

You run the real job with its output `tee`'d to a log, and append a **done marker** line when it exits:

```bash
tmux new -d -s copy \
  "rsync -avh --info=progress2 /mnt/old/ /mnt/new/ 2>&1 | tee /var/log/copy.log; \
   echo MIGRATION_STEP_DONE exit=\$? >> /var/log/copy.log"
```

Then, in a second session, point the watcher at that log:

```bash
tmux new -d -s copy-watch \
  "migration-watch.sh --mode rsync --label 'Copy to new disk' --log /var/log/copy.log"
```

Every `--poll-interval` seconds it reads the newest progress percentage from the log. When a new 10% step is crossed, it sends a notification. When it sees `MIGRATION_STEP_DONE exit=N`, it sends the final notification (success if N is 0, failure otherwise) and exits.

It only looks at log content written **after the watcher started**, so a done marker left in the file by an earlier run can't trigger a false "completed".

## Modes

| `--mode` | Progress source | Done signal |
|---|---|---|
| `rsync` | Last `NN%` in the log (`rsync --info=progress2`) | Done marker |
| `snapraid` | Last `NN%, NNNN MB` line (sync/scrub/check progress) | Done marker |
| `balance` | Computed from the free-space spread across `--balance-mounts`, narrowing towards `--balance-target` | `mergerfs.balance`'s own final `Branches within` line (no marker needed) |
| `waitonly` | None, for jobs with no progress output (e.g. `sha256sum`) | Done marker |

In `balance` mode the job is only reported as finished when `mergerfs.balance` itself prints its final line. That line never appears if the process was killed, so a `systemctl stop` or `kill` isn't mistaken for completion.

## Options

| Option | Default | Meaning |
|---|---|---|
| `--mode MODE` | *(required)* | See the table above |
| `--label TEXT` | *(required)* | Step name used in notifications |
| `--log PATH` | *(required)* | The log the real job writes to |
| `--done-marker STR` | `MIGRATION_STEP_DONE` | Line that marks completion; include `exit=N` after it |
| `--poll-interval SEC` | `60` | How often to check the log |
| `--email-to ADDR` | `EMAIL_TO` from config | |
| `--email-account NAME` | `MSMTP_ACCOUNT` from config | |
| `--ntfy-url URL` | `NTFY_URL` from config | |
| `--ntfy-token TOKEN` | `NTFY_TOKEN` from config | |
| `--balance-mounts LIST` | *(required for `balance`)* | Comma-separated branch mounts, e.g. `/mnt/data1,/mnt/data2` |
| `--balance-target N` | `2.0` | Target spread in percentage points; match `mergerfs.balance -p` |

## Notifications

Both email and ntfy are used for each notification. An empty setting disables that channel.

| Event | Title | ntfy priority |
|---|---|---|
| Each new 10% step | `Migration progress: <label> — 40%` | 2 (low) |
| Done, exit 0 | `Migration step completed: <label>` | 2 (low) |
| Done, non-zero exit | `Migration step FAILED (exit N): <label>` | 5 (urgent) |

Progress notifications include an **estimated completion time**, converted from the tool's own remaining-time estimate: `H:MM ETA` for snapraid, and the trailing `H:MM:SS` for rsync. It's left out until the tool prints an estimate. `balance` and `waitonly` don't estimate.

## Example

```
Title: Migration progress: Copy to new disk — 40%

Copy to new disk is 40% complete.

Estimated completion: 2026-09-24 18:40 MDT

Log: /var/log/copy.log
Host: myserver
Time: 2026-09-24 14:12:03 MDT
```

## Pairs with

- [sync-guard](sync-guard.md) adds crash and stall detection for jobs run in the foreground of a tmux pane. It writes the done marker for you, so you don't need the `echo MIGRATION_STEP_DONE` part.
- [balance-monitor](balance-monitor.md) is a live terminal view of a balance, to run alongside this watcher.
