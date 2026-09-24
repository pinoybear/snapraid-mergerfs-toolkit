# snapraid-mergerfs-toolkit

Bash scripts and systemd units for running a [SnapRAID](https://www.snapraid.it/) + [mergerfs](https://github.com/trapexit/mergerfs) array unattended on a home server — including one where Docker containers (the *arr stack, Nextcloud, Immich, …) write to the array, possibly from a separate VM.

Every script here exists because something simpler failed in practice. The design notes in each script's header explain the specific failure it guards against.

## What's included

| Script | What it does |
|---|---|
| `bin/snapraid-sync.sh` | Nightly `touch` + `sync`. Before syncing it waits for in-flight Sonarr/Radarr/Lidarr imports to finish, optionally puts Uptime Kuma into maintenance, and `docker pause`s the containers that write to the array (locally or over SSH). Afterwards it **always** unpauses them, verifies they return healthy, and exits maintenance, even if the sync fails. Checks parity disk fill level. Logs data volume and throughput per run. |
| `bin/snapraid-scrub-trigger.sh` | Day-gate that runs after every *successful* sync (systemd `OnSuccess=`) and hands off to the scrub once N days have passed. There's no fixed-time scrub timer that could race a long sync. |
| `bin/snapraid-scrub.sh` | `snapraid scrub -p N`, then appends `snapraid status` to the log. |
| `bin/snapraid-check.sh` | Manual full `snapraid check` with live output, a log, and a summary notification. |
| `bin/migration-watch.sh` | Progress notifier for long manual jobs (rsync onto a new disk, `snapraid sync/scrub`, `mergerfs.balance`, or anything that writes a done marker). Sends a notification at each 10% with an ETA, and another on completion or failure. |
| `bin/sync-guard.sh` | Crash and stall detector for a long command running in the foreground of an interactive tmux pane. Pairs with `migration-watch.sh`. |
| `bin/balance-monitor.sh` | Live terminal dashboard for `mergerfs.balance`: per-branch usage, free-space spread, progress, and ETA, with periodic ntfy pushes. |
| `bin/kuma-maintenance.py` | Optional. Toggles an Uptime Kuma *Manual* maintenance window from scripts. |

Notifications go to [ntfy](https://ntfy.sh) and/or email via `msmtp`. Either can be disabled.

## Requirements

- `snapraid`, `bash` ≥ 4.4, `curl`, `python3` (used to parse *arr API JSON)
- Optional: `msmtp` (email), `docker` locally or reachable over key-based SSH, `tmux` (sync-guard), `bc` + `mergerfs-tools` (balance tools), `uptime-kuma-api` Python package (Kuma helper)

## Install

```bash
git clone https://github.com/pinoybear/snapraid-mergerfs-toolkit.git
cd snapraid-mergerfs-toolkit

sudo install -m 755 bin/* /usr/local/bin/
sudo install -m 600 config/snapraid-toolkit.conf.example /etc/snapraid-toolkit.conf
sudo vi /etc/snapraid-toolkit.conf          # set NTFY_URL / EMAIL_TO / PAUSE_CONTAINERS ...

sudo install -m 644 systemd/*.service systemd/*.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now snapraid-sync.timer
```

Do a test run first and watch the log:

```bash
sudo systemctl start snapraid-sync.service
sudo tail -f /var/log/snapraid.log
```

`config/snapraid.conf.example` is a starting point for `/etc/snapraid.conf` with exclusions for files that are always changing (WALs, journals, caches).

## Configuration

All site-specific settings live in `/etc/snapraid-toolkit.conf`, which is sourced as bash. See [`config/snapraid-toolkit.conf.example`](config/snapraid-toolkit.conf.example) for every option. The important ones:

- `PAUSE_CONTAINERS=(...)`: containers that write to the array. SnapRAID fails a sync when a file changes while it's being read, so pause anything that writes there.
- `DOCKER_SSH_DEST="user@host"`: set this when Docker runs on a different machine (e.g. a VM that mounts the array over NFS). Leave it empty for local Docker.
- `ARR_INSTANCES=("sonarr|http://host:8989|/path/to/sonarr/config.xml")`: optional import quiesce. Each API key is read from the app's own `config.xml`, so no second copy is stored.
- `KUMA_MAINTENANCE=("http://kuma:3001|<maintenance id>")`: optional. Put `KUMA_USER=` / `KUMA_PASSWORD=` in `KUMA_CREDENTIALS_FILE` (mode 600).

Point any script at a different config with `SNAPRAID_TOOLKIT_CONF=/path/to/file`.

### Notes

- If `DOCKER_SSH_DEST` is set, the SSH user needs access to `docker` (e.g. membership in the `docker` group) and read access to the *arr `config.xml` files.
- Scripts only send plain arguments over SSH (no pipes or regexes), so they work even when the remote login shell is fish or another non-POSIX shell.
- `snapraid-scrub.service` is for manual runs. The normal path is `snapraid-sync.service` → `OnSuccess=` → `snapraid-scrub-check.service` → scrub, when due.

## Watching a long manual job

```bash
# pane 1: the job itself, with a done marker appended
tmux new -s balance "mergerfs.balance -p 2 /mnt/storage 2>&1 | tee /var/log/balance.log"
# pane 2: live dashboard
balance-monitor.sh --pool /mnt/storage
# pane 3: 10% progress + completion notifications
migration-watch.sh --mode balance --label "Rebalance after adding disk" \
    --log /var/log/balance.log --balance-mounts /mnt/data1,/mnt/data2,/mnt/data3,/mnt/data4
```

See `systemd/examples/` for running `sync-guard.sh` and `migration-watch.sh` as services.

## License

MIT
