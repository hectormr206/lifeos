# LifeOS Incident Response Playbook

This playbook defines operational steps for production incidents in LifeOS.
It focuses on fast containment, deterministic rollback, and auditable recovery.

## 1. Severity model

- `SEV-1`: System unavailable, data integrity risk, or privileged compromise.
- `SEV-2`: Core feature degraded (updates, AI runtime, permissions) with workaround.
- `SEV-3`: Non-critical regression with limited user impact.

## 2. First 10 minutes (triage)

1. Capture current status:
   - `life status --detailed`
   - `life check`
   - `sudo journalctl -u lifeosd -n 200 --no-pager`
2. Freeze update pressure:
   - `life update status`
   - If needed: switch channel to stable only.
3. Classify severity and open an incident timeline in internal tracking.

## 3. Containment patterns

### 3.1 AI/runtime containment

1. Stop AI runtime if unsafe behavior is detected:
   - `life ai stop`
2. Disable autonomous trust mode immediately:
   - `life onboarding trust-mode disable --actor user://incident/commander`
3. Force interactive execution mode:
   - `life intents mode set interactive --actor user://incident/commander`

### 3.2 Permissions containment

1. Inspect current grants:
   - `life permissions show`
2. Revoke compromised grants:
   - `life permissions revoke <app_id> --resource <resource>`
   - `life permissions revoke <app_id>` (all resources)
3. Review permission activity:
   - `life permissions log --lines 200`

## 4. Rollback and recovery

### 4.1 Atomic rollback (preferred)

1. Validate candidate deployment state:
   - `life update status`
2. Trigger rollback:
   - `life rollback`
3. Reboot if prompted and verify:
   - `life check`
   - `life status --detailed`

### 4.2 Runtime recovery

1. Run guided diagnostics:
   - `life recover`
2. Re-check critical services:
   - `sudo systemctl status lifeosd`
   - `sudo systemctl status llama-server`
3. Confirm health gates:
   - `life check`

## 5. Artifact revocation workflow

Use this workflow when an image/model artifact is compromised.

1. Mark artifact as revoked in release metadata/TUF targets.
2. Rotate signing material (cosign/GPG) if key compromise is suspected.
3. Publish updated trusted metadata (timestamp/snapshot/targets).
4. Force update checks on affected systems:
   - `life update check`
5. Confirm clients reject revoked artifact and accept replacement.

## 6. Evidence and audit requirements

For every incident, collect:

1. Command evidence (timestamps + outputs for status/check/recover/rollback).
2. Relevant journal excerpts (`lifeosd`, `llama-server`, update pipeline).
3. Intent ledger export for autonomous actions:
   - `life intents log --export /tmp/incident-ledger.json --passphrase <secret>`
4. Memory-plane context export if used by agents:
   - `life memory mcp "<incident query>" --limit 10`

## 7. Exit criteria

Incident is closed only when:

1. All SEV-1/SEV-2 symptoms are resolved and validated in `life check`.
2. Rollback path is verified (or not needed and explicitly justified).
3. Revocation and replacement artifacts are published (if applicable).
4. Postmortem is written with root cause, blast radius, and follow-up actions.

## 8. Postmortem template (minimum)

1. Summary and impact window.
2. Root cause and triggering conditions.
3. Detection quality and timeline.
4. What worked / what failed in response.
5. Permanent corrective actions with owners and due dates.
