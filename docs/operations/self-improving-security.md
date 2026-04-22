# Self-Improving Daemon — Security Model

The self-improving subsystem (`daemon/src/self_improving.rs`) reads supervisor audit logs, records user actions, detects repeating patterns, and runs nightly optimisation. Several of these surfaces touch persisted state on disk, which is reachable by any process that can write to `/var/lib/lifeos/`. This document captures how the daemon limits the blast radius.

## Threat model

- **Same-UID process with full filesystem access** — out of scope. Anything running as `lifeos` already wins.
- **Process under another UID, or a sandboxed payload** (flatpak app, systemd-run scope) that can write into `/var/lib/lifeos/` but cannot read `/var/lib/lifeos/secrets/` (mode 0700) — IN scope.
- **Backup/restore that brings stale or attacker-supplied state from another machine** — IN scope.
- **Supply chain that drops a `workflow_actions.json` during cargo build, install, or migration** — IN scope.

## `workflow_actions.json` integrity

The file is paired with a sibling `workflow_actions.json.hmac` that contains a hex HMAC-SHA256 of the JSON payload. The signing key lives at `/var/lib/lifeos/secrets/workflow-hmac.key` (32 random bytes, mode 0600; parent dir mode 0700). It is generated on first use.

On load:

1. If the sidecar is missing, the file is refused (treated as untrusted) and an empty list is returned.
2. If the HMAC does not verify, the file is refused.
3. If the JSON parses but fails the schema (see below), the file is refused.

Refusals are loud (`warn!`) but fail-safe: the daemon proceeds with no learned actions rather than risking an attacker-controlled pattern feeding back into the supervisor.

If the secrets directory is not writable (some test environments), the learner falls back to no signing, logged at `warn!`. Existing reads still work, the trust level is just lower.

## Schema validation

Both `record_action` and `load_actions` enforce:

- Action name matches `[a-z0-9_-]+`, length 1..=64. No uppercase, no shell metacharacters, no path separators, no whitespace, no Unicode lookalikes.
- Context length ≤ 256 bytes.
- Total recorded actions ≤ 1000.

A file that violates any of these is refused on load.

## `check_auto_trigger` opt-in

The function that turns a learned pattern into a sequence proposed back to the supervisor returns `None` unless `LIFEOS_AUTO_TRIGGER_ENABLE=1` (or `true`/`yes`/`on`) is set. Defence in depth alongside HMAC: even if an attacker manages to bypass signing, the auto-execution path is closed by default.

## Nightly optimiser presence check

`should_run` previously treated a *missing* `presence_detected` file as "user is idle, run cleanup". A local attacker could `rm` the file to make the optimiser run while the user was active, deleting journals/cache they were working on.

The check now **fails closed**: if the presence file is missing or unreadable, the optimiser does not run. The cost is that on a fresh install nightly waits until the sensory pipeline has touched the file at least once. The installer (or a first-boot script) can pre-create it.

## Nightly cleanup symlink safety

`cleanup_old_files` walks `journals/` and `cache/` removing files older than the retention window. It now uses `fs::symlink_metadata` (no follow) and skips entries that aren't regular files. Without this guard, a symlink in `journals/` pointing at e.g. `~/important-old.txt` would have been removed as if it were a stale journal.

## Opting in to auto-trigger

Add a systemd drop-in for the user-session daemon and reload:

```
mkdir -p ~/.config/systemd/user/lifeosd.service.d
printf '[Service]\nEnvironment=LIFEOS_AUTO_TRIGGER_ENABLE=1\n' \
  > ~/.config/systemd/user/lifeosd.service.d/60-auto-trigger.conf
systemctl --user daemon-reload
systemctl --user restart lifeosd
```

When enabled, the daemon may propose multi-step sequences detected from your past actions back to the supervisor. Audit them in `journalctl --user -u lifeosd | rg WorkflowLearner`.

## What this PR does **not** do

- Does not protect against a same-UID attacker. The HMAC key is readable by the daemon's user; anyone running code as that user can sign new payloads.
- Does not validate the supervisor audit log (`/var/lib/lifeos/supervisor-audit.log`). That file is consumed read-only by `PromptEvolution`; bad data degrades suggestions but doesn't enable execution. A signature on the audit log is a separate hardening item.
- Does not sandbox the cleanup walks. If `journals/` or `cache/` directories are themselves attacker-controlled, deleting old files in them is the desired behaviour.
