# snapraid-scrub-trigger.sh + snapraid-scrub.sh

A weekly scrub that only ever starts after a successful nightly sync, so the two never overlap.

**Runs from:** `snapraid-sync.service` → `OnSuccess=snapraid-scrub-check.service` → `snapraid-scrub-trigger.sh` → (if due) `snapraid-scrub.sh`.

## Why not a scrub timer?

A sync can take anywhere from minutes to hours, depending on how much changed that day. A scrub on its own fixed timer will eventually start while a sync is still running. Chaining the scrub to the sync's *success* removes that race entirely, and it also means no scrub runs on top of a sync that just failed.

## snapraid-scrub-trigger.sh

A day-gate. It reads the modification time of `SCRUB_STATE_FILE`:
- If the last scrub was fewer than `SCRUB_MIN_GAP_DAYS` ago, it logs and exits 0.
- Otherwise, or if the state file doesn't exist yet (first run), it hands off to `snapraid-scrub.sh` in the same directory.

It only *reads* the state file. `snapraid-scrub.sh` writes it, and only after acquiring its own lock. So a scrub that couldn't start (because another scrub or a sync held the lock) doesn't wrongly count as done.

## snapraid-scrub.sh

1. **Lock checks.** Exits 1 if another scrub is running. Exits 0 (defers) if a sync is running.
2. **Stamps `SCRUB_STATE_FILE`** with the current time.
3. **`snapraid scrub -p SCRUB_PERCENT`.** Scrubs the oldest-checked N% of the array.
4. **On success,** appends a `snapraid status` snapshot to the log. **On failure,** sends an alert with the last 50 lines of scrub output.

It can also be started manually with `sudo systemctl start --no-block snapraid-scrub.service`. That unit won't start while the sync's lock file exists.

## Configuration

| Setting | Default | Meaning |
|---|---|---|
| `SCRUB_PERCENT` | `8` | Percent of the array per scrub (`snapraid scrub -p`) |
| `SCRUB_MIN_GAP_DAYS` | `7` | Minimum days between scrubs |
| `SCRUB_STATE_FILE` | `/var/lib/snapraid/last-scrub-run` | Its modification time is the "last scrub" date |
| `LOG_FILE` | `/var/log/snapraid.log` | Shared with the sync |

`-p 8` weekly is SnapRAID's own recommendation: every block gets re-verified about every 12 weeks.

## Example log

Not due yet (most nights):

```
2026-09-24 01:52:13 - [SCRUB-TRIGGER] Last scrub was 3 day(s) ago (need 7). Not due yet, skipping.
```

Due:

```
2026-09-27 01:48:40 - [SCRUB-TRIGGER] Scrub is due -- handing off to /usr/local/bin/snapraid-scrub.sh
2026-09-27 01:48:40 - [SCRUB] Starting SnapRAID Scrub on myserver...
2026-09-27 01:48:40 - [SCRUB] Running snapraid scrub -p 8...
   ...snapraid's own scrub output...
2026-09-27 03:10:22 - [SCRUB] Scrub Complete Successfully.
--- SnapRAID Status Snapshot ---
   ...snapraid status output...
--------------------------------
```

## Alerts

| Title | Priority | When | What to do |
|---|---|---|---|
| `SnapRAID SCRUB FAIL` | 5 (urgent) | `snapraid scrub` exited non-zero | Read the attached output. Data errors (silent corruption found) show up as bad blocks: run `snapraid -e fix` to repair them from parity, then `snapraid -p bad scrub` to verify. A failing disk will also show up in its SMART data. |

A clean scrub sends no notification. The status snapshot is in the log if you want it.
