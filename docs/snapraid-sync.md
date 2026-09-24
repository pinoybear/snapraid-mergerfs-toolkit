# snapraid-sync.sh

Nightly `snapraid touch` + `snapraid sync` that first quiets everything writing to the array, and always puts things back afterwards.

**Runs from:** `snapraid-sync.timer` → `snapraid-sync.service` (01:35 nightly by default). On success, systemd starts the [scrub check](snapraid-scrub.md) via `OnSuccess=`.

## What it does, in order

1. **Lock checks.** Exits if another sync is running. Exits cleanly (code 0) if a scrub is running, deferring to the next night. A lock file left by a dead process is removed.
2. **Parity pre-check.** Fails immediately if `PARITY_MOUNT` doesn't exist (e.g. the disk didn't mount). Warns, but continues, if it's at or above `PARITY_WARN_PERCENT` full.
3. **\*arr quiesce** (only if `ARR_INSTANCES` is set). For each app, polls its `/api/v3/command` endpoint and waits while any command is `started` or `queued`, up to `ARR_QUIET_MAX_RETRIES × ARR_QUIET_RETRY_DELAY` (default 8 × 15s = 2 minutes). If it's still busy after that, it logs a warning and carries on. If the API can't be reached or the key can't be read, it also carries on: this check only narrows the race window, and never blocks a sync.
4. **Kuma maintenance** (only if `KUMA_MAINTENANCE` is set). Enters each listed maintenance window, so monitors don't alert on paused containers.
5. **Pause.** For each name in `PAUSE_CONTAINERS` that is currently running and not already paused: `docker pause`, then re-reads the live state to confirm it really is paused. Only confirmed pauses are tracked for unpausing later.
6. **`snapraid touch`.** A non-zero exit is logged and ignored.
7. **`snapraid sync`.** Logs the data volume and average throughput. On failure, sends an alert that includes the tail of `snapraid diff`.
8. **Cleanup** (runs on *every* exit, via an `EXIT` trap):
   - Unpauses every tracked container first (3 attempts each), *then* polls all of them round-robin until each is `running` and `healthy` (or has no healthcheck), for up to 30 × 10s = 5 minutes. A container something else already unpaused counts as success.
   - Exits the Kuma maintenance windows.

## Configuration

All in `/etc/snapraid-toolkit.conf`:

| Setting | Default | Meaning |
|---|---|---|
| `PARITY_MOUNT` | `/mnt/parity1` | Must exist or the sync fails immediately |
| `PARITY_WARN_PERCENT` | `98` | Warn when the parity disk is this full |
| `LOG_FILE` | `/var/log/snapraid.log` | Shared with the scrub scripts |
| `PAUSE_CONTAINERS` | `()` | Containers to pause during the sync |
| `DOCKER_SSH_DEST` | *(empty = local)* | `user@host` to run `docker` over SSH (key auth, `BatchMode=yes`) |
| `ARR_INSTANCES` | `()` | `"name\|base_url\|path/to/config.xml"` per app |
| `ARR_QUIET_MAX_RETRIES` / `ARR_QUIET_RETRY_DELAY` | `8` / `15` | How long to wait on a busy *arr app |
| `KUMA_MAINTENANCE` | `()` | `"base_url\|maintenance_id"` per Kuma instance |
| `KUMA_HELPER` | `/usr/local/bin/kuma-maintenance.py` | See [kuma-maintenance](kuma-maintenance.md) |
| `KUMA_CREDENTIALS_FILE` | `/root/.config/kuma.env` | Defines `KUMA_USER` and `KUMA_PASSWORD` |
| `HOST_LABEL` | hostname | Name used in alert text |

Notification settings (`NTFY_URL`, `NTFY_TOKEN`, `EMAIL_TO`, `MSMTP_ACCOUNT`) are shared by all scripts; see the [docs index](README.md#shared-behavior).

### About `ARR_INSTANCES`

The API key is read from each app's own `config.xml`, on the Docker host (over SSH if `DOCKER_SSH_DEST` is set), so no second copy of the key is stored. The SSH user needs read access to that file. Works with Sonarr, Radarr and Lidarr, or anything else that serves the `/api/v3/command` endpoint.

## Example log

A normal night, with *arr quiesce enabled and one app busy at first:

```
2026-09-24 01:35:00 - [SYNC] Starting SnapRAID Sync on myserver...
2026-09-24 01:35:00 - [SYNC] Checking *arr apps for active imports before pausing...
2026-09-24 01:35:01 - [SYNC] sonarr has an active command [DownloadedEpisodesScan]; waiting before pausing (attempt 1/8)...
2026-09-24 01:35:16 - [SYNC] sonarr is quiet now, proceeding.
2026-09-24 01:35:18 - [SYNC] Entered Kuma maintenance window(s).
2026-09-24 01:35:18 - [SYNC] Pausing active write containers to prevent file churn...
2026-09-24 01:35:19 - [SYNC] Paused container: sonarr
2026-09-24 01:35:19 - [SYNC] Paused container: radarr
2026-09-24 01:35:20 - [SYNC] Running snapraid touch...
2026-09-24 01:35:24 - [SYNC] Running snapraid sync...
2026-09-24 01:52:07 - [SYNC] Sync data volume: ~48213 MB moved in 1003s (~48 MB/s wall-clock avg).
2026-09-24 01:52:07 - [SYNC] Sync Complete Successfully.
2026-09-24 01:52:07 - [SYNC] Unpausing and verifying containers...
2026-09-24 01:52:08 - [SYNC] Unpaused container: sonarr
2026-09-24 01:52:08 - [SYNC] Unpaused container: radarr
2026-09-24 01:52:09 - [SYNC] Container sonarr is now: running (Health: healthy)
2026-09-24 01:52:09 - [SYNC] Container radarr is now: running (Health: none)
2026-09-24 01:52:12 - [SYNC] Exited Kuma maintenance window(s).
```

`Health: none` means the container has no Docker healthcheck. That counts as healthy once it's running.

## Alerts

| Title | Priority | When | What to do |
|---|---|---|---|
| `SnapRAID SYNC FAIL` | 5 (urgent) | Parity mount missing, or `snapraid sync` exited non-zero | Read the attached `snapraid diff` tail. The two usual causes: a file changed mid-sync (add its container to `PAUSE_CONTAINERS`, or exclude the path in `snapraid.conf`), or SnapRAID refused because a whole data disk now looks empty, usually because it didn't mount. Check `mount` first. Only if the disk really is meant to be empty, run `snapraid sync --force-empty` by hand. |
| `SnapRAID WARNING` | 3 | Parity disk at or above `PARITY_WARN_PERCENT` | The parity disk must be at least as large as your largest data disk; plan for a bigger one. |
| `SnapRAID UNPAUSE FAIL` | 5 (urgent) | A container failed to unpause, or wasn't healthy within 5 minutes | The alert names each container and its final state. Check it with `docker ps` / `docker logs`. |
| `SnapRAID KUMA MAINTENANCE STUCK` | 3 | Exiting a Kuma maintenance window failed | Clear maintenance manually in the Kuma UI. Until then, Kuma suppresses real alerts for those monitors. |

Urgent alerts also include the last 25 lines of `LOG_FILE`, with progress-bar lines removed.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Sync succeeded, or deferred because a scrub was running |
| `1` | Not root, another sync already running, parity mount missing, or sync failed |

Only exit 0 triggers the scrub check. A deferred night also counts as exit 0, but the scrub check will then skip if a scrub ran recently.
