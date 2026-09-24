# snapraid-check.sh

A manual, full `snapraid check`: every block on every disk is read and verified against parity. Streams live output to your terminal, saves it to a log, and sends a clean/errors summary when it finishes.

**Runs:** manually only. A full check reads the whole array, so expect hours on a large one. Run it inside `tmux` so a dropped SSH session doesn't kill it.

```bash
tmux new -s check 'sudo snapraid-check.sh'
```

## When to use it

- After replacing or re-adding a disk, or recovering from `snapraid fix`.
- Before trusting an array you haven't verified in a long time.
- The weekly [scrub](snapraid-scrub.md) covers routine verification; this is the "check everything now" version.

## Configuration

| Setting | Default | Meaning |
|---|---|---|
| `CHECK_LOG_FILE` | `/var/log/snapraid-check.log` | Separate from the nightly log |
| `HOST_LABEL` | hostname | Name used in the alert title |

Plus the shared notification settings (see the [docs index](README.md#shared-behavior)).

## Notifications

| Result | ntfy title | Priority | ntfy body | Email body |
|---|---|---|---|---|
| Exit 0 | `SnapRAID Check Clean - <host>` | 3 | "No errors found." | Full output |
| Non-zero exit | `SnapRAID Check ERRORS - <host>` | 5 (urgent) | Last 5 lines of output | Full output |

The ntfy message stays short. The email always carries the complete check output, so you have the full record when something is wrong.

## Example terminal output (abbreviated)

```
=== SnapRAID Check Started at 2026-09-24 10:00:00 ===
Self test...
Loading state from /var/snapraid.content...
Checking...
100% completed, 11203440 MB accessed in 14:02
Everything OK
=== SnapRAID Check Finished with exit code 0 ===
=== Notifications dispatched ===
```

## Exit code

The script exits with `snapraid check`'s own exit code, so it can be chained in other scripts.
