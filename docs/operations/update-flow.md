# Update Flow

LifeOS uses a **check → stage → apply** update model. No step is automatic; the user
controls when each phase runs, and reboot is always user-initiated.

---

## Phases

```
┌─────────────────┐       ┌─────────────────┐       ┌─────────────────┐
│  CHECK          │──────▶│  STAGE          │──────▶│  APPLY          │
│ (daily timer)   │       │ (weekly timer)  │       │ (user-initiated)│
│                 │       │                 │       │                 │
│ bootc upgrade   │       │ bootc upgrade   │       │ user reboots    │
│   --check       │       │ (no --apply)    │       │ into staged     │
│                 │       │                 │       │ deployment      │
│ writes:         │       │ writes:         │       │                 │
│ update-state    │       │ update-stage-   │       │ (or runs        │
│ .json           │       │ state.json      │       │ bootc rollback) │
└─────────────────┘       └─────────────────┘       └─────────────────┘
```

### Check

- Triggered by `lifeos-update-check.timer` (daily) or manually via `life update check`.
- Runs `bootc upgrade --check` — a read-only probe, no download.
- Writes result to `/var/lib/lifeos/update-state.json`.
- Emits a desktop notification and a POST to the Axi daemon API if an update is available.

### Stage

- Triggered by `lifeos-update-stage.timer` (weekly, Sunday 04:00 + 30 min jitter) or
  manually via `life update stage`.
- Runs `bootc upgrade` (no `--apply`) — downloads and stages the new deployment.
- Writes result to `/var/lib/lifeos/update-stage-state.json`.
- If staging fails the file preserves the last successful staging result (`staged_digest`,
  `staged_at`) and records the error in `last_stage_error`.
- Emits notifications on state change: "Update staged — reboot to activate" on success,
  "Update staging failed — see logs" on failure.
- **Idempotent**: if the current staged digest already matches the remote digest,
  exits 0 with "already staged, no-op" — `bootc upgrade` is not called again.

### Apply

- Never automatic. The user triggers it by running `sudo bootc upgrade --apply` (or the
  equivalent bootc flow). The `life update apply` command **only prints the manual command**
  — it never executes it.
- A staged deployment activates on the next boot: `sudo reboot`.
- The dashboard "Activate update" button guides the user through this flow.

---

## State File Schema

### `/var/lib/lifeos/update-state.json`

Written by `lifeos-update-check.sh`:

```json
{
  "available": true,
  "current_version": "sha256:abc...",
  "current_digest": "sha256:abc...",
  "new_version": "sha256:def...",
  "remote_digest": "sha256:def...",
  "checked_at": "2026-04-15T04:00:00+00:00",
  "error": null
}
```

| Field | Type | Description |
|-------|------|-------------|
| `available` | bool | `true` if a newer image is available at the remote |
| `current_digest` | string\|null | Digest of the currently booted deployment |
| `remote_digest` | string\|null | Digest of the latest image on GHCR |
| `checked_at` | ISO8601 | Timestamp of the last successful check |
| `error` | string\|null | Error message if the last check failed |

### `/var/lib/lifeos/update-stage-state.json`

Written by `lifeos-update-stage.sh`:

```json
{
  "staged": true,
  "staged_digest": "sha256:def...",
  "staged_at": "2026-04-15T04:05:23+00:00",
  "last_stage_attempt": "2026-04-15T04:05:23+00:00",
  "last_stage_error": null
}
```

| Field | Type | Description |
|-------|------|-------------|
| `staged` | bool | `true` if a deployment is currently staged |
| `staged_digest` | string\|null | Digest of the staged deployment |
| `staged_at` | ISO8601\|null | Timestamp of the last successful staging |
| `last_stage_attempt` | ISO8601\|null | Timestamp of the last staging attempt (success or fail) |
| `last_stage_error` | string\|null | Error message from the last failed staging |

**Failure-preservation rule**: on a transient failure, `staged_digest` and `staged_at`
are NOT overwritten — only `last_stage_error` and `last_stage_attempt` are updated. This
keeps the dashboard showing the last known good staged deployment while surfacing the error.

---

## CLI Subcommands

All `life update` subcommands read the state files above. They require no elevated
privileges to run (file reads only), except `check` and `stage` which trigger systemd
services via `systemctl start`.

```bash
life update status            # Print merged view of both state files + booted image
life update status --json     # Same as structured JSON

life update check             # Trigger lifeos-update-check.service (systemctl start)
life update stage             # Trigger lifeos-update-stage.service (systemctl start)

life update apply             # Print manual sudo command — NEVER executes it
life update rollback          # Print manual rollback command — NEVER executes it
```

### `life update status` output

```
Booted:   ghcr.io/hectormr206/lifeos:edge @ sha256:abc...
Checked:  2026-04-15T04:00:00+00:00   (available: yes)
Remote:   sha256:def...
Staged:   sha256:def...  (staged at: 2026-04-15T04:05:23+00:00)
Error:    none
```

### `life update apply` output

```
Staged deployment: sha256:def...
Current deployment: sha256:abc...

To activate, run this command and reboot:
  sudo bootc upgrade --apply

Or use the dashboard 'Activate update' button.
```

---

## Dashboard Interaction

The LifeOS dashboard (`http://127.0.0.1:8081/dashboard`) polls
`GET /api/v1/updates/status` every 60 seconds and surfaces:

- A banner when an update is available.
- A "Stage update" button that POSTs to the daemon, which calls
  `systemctl start lifeos-update-stage.service`.
- An "Activate update" button (shown when `staged` is true) that guides the user
  through the manual `sudo bootc upgrade --apply` + reboot flow.
- An error banner when `last_stage_error` is non-null.

---

## Systemd Units

| Unit | Type | Schedule | Purpose |
|------|------|----------|---------|
| `lifeos-update-check.timer` | timer | Daily (04:00) | Triggers the check service |
| `lifeos-update-check.service` | oneshot | — | Runs `bootc upgrade --check`, writes state |
| `lifeos-update-stage.timer` | timer | Weekly (Sun 04:00 + 30 min jitter) | Triggers the stage service |
| `lifeos-update-stage.service` | oneshot | — | Runs `bootc upgrade` (no apply), writes stage state |

To run either service manually:

```bash
sudo systemctl start lifeos-update-check.service
sudo systemctl start lifeos-update-stage.service
```

To inspect the timer schedule:

```bash
systemctl list-timers lifeos-update-check.timer lifeos-update-stage.timer
```

---

## Rollback

```bash
# Print rollback info and manual command
life update rollback

# Run the actual rollback
sudo bootc rollback
```

`bootc` retains at least the last two deployments at all times. Running
`sudo bootc rollback` schedules the previous deployment to boot on the next startup —
it does not reboot the system immediately.

After rolling back, check the state:

```bash
bootc status
life update status
```

---

## Cadence Override

To change the staging schedule (e.g., to stage daily instead of weekly), install a
systemd dropin:

```bash
sudo mkdir -p /etc/systemd/system/lifeos-update-stage.timer.d/
sudo tee /etc/systemd/system/lifeos-update-stage.timer.d/10-cadence.conf > /dev/null <<'EOF'
[Timer]
OnCalendar=
OnCalendar=*-*-* 04:00:00
RandomizedDelaySec=1800
EOF
sudo systemctl daemon-reload
```

---

## See Also

- [`docs/operations/developer-bootstrap.md`](developer-bootstrap.md) — dev workstation setup
- [`docs/architecture/update-channels.md`](../architecture/update-channels.md) — channel model
- [`docs/operations/system-admin.md`](system-admin.md) — systemd unit reference
