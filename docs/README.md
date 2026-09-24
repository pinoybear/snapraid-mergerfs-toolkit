# Documentation

One page per tool. Each covers what it does, every option, what the log output looks like, and what each alert means.

## Nightly automation

| Page | Runs from | Summary |
|---|---|---|
| [snapraid-sync](snapraid-sync.md) | `snapraid-sync.timer` | Nightly `touch` + `sync` with container pause, *arr quiesce and Kuma maintenance |
| [snapraid-scrub](snapraid-scrub.md) | `OnSuccess=` of the sync | Day-gated weekly scrub (`snapraid-scrub-trigger.sh` + `snapraid-scrub.sh`) |

## Manual tools

| Page | Summary |
|---|---|
| [snapraid-check](snapraid-check.md) | Full `snapraid check` with live output and a summary notification |
| [migration-watch](migration-watch.md) | 10% progress + completion notifications for any long job that writes a log |
| [sync-guard](sync-guard.md) | Crash and stall detection for a long job in an interactive tmux pane |
| [balance-monitor](balance-monitor.md) | Live terminal dashboard for `mergerfs.balance` |
| [kuma-maintenance](kuma-maintenance.md) | Toggle an Uptime Kuma maintenance window from a script |

## Shared behavior

- **Config:** every script sources `/etc/snapraid-toolkit.conf` (override with `SNAPRAID_TOOLKIT_CONF=/path`). See [`config/snapraid-toolkit.conf.example`](../config/snapraid-toolkit.conf.example).
- **Notifications:** ntfy (`NTFY_URL`, optional `NTFY_TOKEN`) and/or email via msmtp (`EMAIL_TO`, `MSMTP_ACCOUNT`). An empty setting disables that channel; both can be on at once.
- **Log format:** `YYYY-MM-DD HH:MM:SS - [TAG] message`. The nightly scripts share `/var/log/snapraid.log`, tagged `[SYNC]`, `[SCRUB-TRIGGER]` and `[SCRUB]`.
- **Root:** the SnapRAID scripts refuse to run as a non-root user.
