# sync-guard.sh

Crash and stall detection for a long command you started by hand in the **foreground of an interactive tmux pane**, e.g. a `snapraid sync --force-full` that will run for a day.

It works alongside [migration-watch](migration-watch.md): sync-guard decides *when* and *how* the job ended and writes the done marker to the log, and migration-watch sends the completion or failure notification. On its own, sync-guard also alerts if the log stops moving.

**Runs:** manually, or as a service (see [`systemd/examples/snapraid-manual-sync-guard.service`](../systemd/examples/snapraid-manual-sync-guard.service)). Configured entirely by environment variables.

## Why this is needed

When you type a command into an interactive tmux pane and it finishes (or crashes), tmux doesn't mark the pane as dead. The shell simply returns to a prompt. So "is the pane dead?" can't tell you the job ended. sync-guard instead watches the pane's **current command**: while the job runs it's `snapraid`, and when the job ends it changes back to your shell.

## What it does

Every `POLL_INTERVAL` seconds:

1. **Job ended?** If the pane's current command is no longer `EXPECTED_CMD`, it rechecks after 5 seconds (to ignore brief blips), then decides the result:
   - Scans the end of the log for SnapRAID's own `WARNING!`, `ERROR!`, `DANGER!` or `Aborting` output. If any appear, it's a failure (`exit=1`); otherwise success (`exit=0`).
   - Writes `MIGRATION_STEP_DONE exit=N` to the log and exits. migration-watch picks that up and notifies.
   - Unclear cases are deliberately reported as failure. A false "failed" alert on a job that actually succeeded is much cheaper than silence after a real crash.
2. **tmux session gone?** If the pane or session no longer exists at all, it writes `exit=unknown` and sends an urgent `CRASHED` alert directly.
3. **Stalled?** If the job is still running but the log hasn't changed for `STALL_THRESHOLD` seconds, it sends one `possibly STALLED` alert. If output resumes, it sends a `resumed` notice.

## Settings (environment variables)

| Variable | Default | Meaning |
|---|---|---|
| `TARGET` | `0` | tmux target (session, `session:window` or pane) the job runs in |
| `EXPECTED_CMD` | `snapraid` | Pane command while the job is running |
| `LOG` | `/var/log/snapraid-manual-force-sync.log` | The log the job `tee`s to |
| `POLL_INTERVAL` | `60` | Seconds between checks |
| `STALL_THRESHOLD` | `1800` | Seconds without log output before a stall alert (30 min) |
| `EMAIL_ACCOUNT` | `MSMTP_ACCOUNT` from config | |
| `NTFY_URL` / `NTFY_TOKEN` / `EMAIL_TO` | from config | Environment values take priority over the config file |

## Example: a manual full sync

```bash
# 1. become root FIRST, then start tmux session 0 and the job inside it
sudo -i
tmux new -s 0
snapraid sync --force-full 2>&1 | tee /var/log/snapraid-manual-force-sync.log

# 2. from another shell, start both watchers
sudo systemctl start snapraid-manual-sync-guard.service snapraid-manual-sync-watch.service
```

(Install the two example units from `systemd/examples/` first.)

Two things that break detection if you get them wrong:
- **tmux must belong to root.** The services run as root and can only see root's tmux sessions. A session started as your normal user is invisible to them.
- **Don't prefix the job with `sudo` inside the pane.** The pane's current command would then be `sudo`, not `snapraid`. Either run as root (as above) or set `EXPECTED_CMD=sudo`.

## Alerts

| Title | Priority | When |
|---|---|---|
| `Migration step CRASHED: Manual --force-full sync` | 5 (urgent) | The tmux session disappeared entirely |
| `Migration step possibly STALLED: Manual --force-full sync` | 4 (high) | No new log output for `STALL_THRESHOLD` seconds while the job still shows as running |
| `Migration step resumed: Manual --force-full sync` | 3 | Output resumed after a stall alert |

Normal completion and failure notifications come from migration-watch, not sync-guard.

> The alert titles currently say "Manual --force-full sync" regardless of what the job is. If you guard a different command, the titles will still read that way.
