# kuma-maintenance.py

Turns an [Uptime Kuma](https://github.com/louislam/uptime-kuma) maintenance window on and off from a script. `snapraid-sync.sh` uses it so Kuma doesn't raise alerts while containers are deliberately paused, but it works for any job.

**Optional.** Only needed if you set `KUMA_MAINTENANCE` in the toolkit config.

## Why not Kuma's scheduled maintenance?

A fixed maintenance window (say 01:30–03:00) either ends before a long sync does, so you get false alerts, or runs long after a short one has finished, which hides real outages. A *Manual* maintenance window toggled at the exact start and end of the pause covers precisely the time the containers are down.

## Setup

1. **Install the library.** A virtual environment is recommended:
   ```bash
   sudo python3 -m venv /opt/kuma-maintenance-venv
   sudo /opt/kuma-maintenance-venv/bin/pip install uptime-kuma-api
   ```
   Then either change the script's first line to `#!/opt/kuma-maintenance-venv/bin/python`, or point `KUMA_HELPER` at a small wrapper script.
2. **Create the maintenance entry in Kuma:** *Maintenance → Add*, strategy **Manual**, and select the monitors for the containers you pause. Its ID is the number at the end of the URL when you open it for editing.
3. **Store the credentials** in `KUMA_CREDENTIALS_FILE` (default `/root/.config/kuma.env`, mode `600`):
   ```bash
   KUMA_USER="admin"
   KUMA_PASSWORD="..."
   ```
4. **Add the instance to the toolkit config:**
   ```bash
   KUMA_MAINTENANCE=("http://kuma.lan:3001|2")
   ```
   Several Kuma instances can be listed; each gets entered and exited.

## Usage

```bash
KUMA_PASSWORD=... kuma-maintenance.py enter        --url http://kuma.lan:3001 --user admin --id 2
KUMA_PASSWORD=... kuma-maintenance.py exit         --url http://kuma.lan:3001 --user admin --id 2
KUMA_PASSWORD=... kuma-maintenance.py set-monitors --url http://kuma.lan:3001 --user admin --id 2 --monitors 5,6,9
KUMA_PASSWORD=... kuma-maintenance.py set-manual   --url http://kuma.lan:3001 --user admin --id 2
```

| Action | Effect |
|---|---|
| `enter` | Turns the maintenance window on |
| `exit` | Turns it off |
| `set-monitors` | **Replaces** the window's monitor list with `--monitors` |
| `set-manual` | Switches an existing window to the Manual strategy |

The password is taken from `KUMA_PASSWORD`, which keeps it out of `ps` output. `--password` also works, but is visible to other users on the machine while the command runs.

## Notes

- **Why a username and password, not an API key:** Kuma's API keys only cover its Prometheus `/metrics` endpoint. Maintenance can only be controlled through the same login the web UI uses.
- **Retries:** `enter` and `exit` re-read the window afterwards to confirm it actually changed state. If it didn't, or the connection failed, they reconnect and try again: up to 5 attempts, 10 seconds apart.
- **Exit code:** `0` on confirmed success, `1` if every attempt failed, so the calling script can react. `snapraid-sync.sh` sends a `KUMA MAINTENANCE STUCK` alert if `exit` fails, because a window left on silently hides real alerts.
