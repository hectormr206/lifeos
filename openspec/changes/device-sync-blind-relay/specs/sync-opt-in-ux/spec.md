# Sync Opt-In UX Specification

## Purpose

Sync-related UI: a connectivity state distinct from VPN reachability, an
opt-in settings surface, the recovery-phrase ceremony entry point, and a
conflict-history view. Sync is additive and MUST NEVER gate a feature —
LifeOS stays fully autonomous on every device, sync or no sync. Backup/VPN
reachability logic (`reachability_vpn_probe.dart`, `vpn_gate.dart`) is out of
scope.

## Requirements

### Requirement: `needsPairing` uses a connectivity state distinct from VPN reachability

The system MUST introduce a connectivity/relay-reachability state, separate
from the existing VPN-reachability signal, to evaluate `needsPairing`
(`mobile/lib/app.dart:155-172`) for sync-capable routes once blind relay
sync is available.

#### Scenario: Relay-reachable device is not blocked by VPN-down state
- GIVEN a device with the VPN down but the blind relay reachable over plain
  internet
- WHEN a sync-gated route is evaluated
- THEN `needsPairing` MUST be evaluated against relay/sync reachability, not
  VPN reachability

### Requirement: Sync is strictly opt-in and additive

The system MUST NOT make any existing or new feature depend on sync being
enabled. Every feature that works fully offline today MUST continue to work
identically with sync disabled.

#### Scenario: All local features work with sync never enabled
- GIVEN a device that has never enabled sync
- WHEN the user uses any local feature (graph, reminders, domains, chat with
  local model, etc.)
- THEN it MUST function exactly as it does today, with no sync-related
  prompt, block, or degradation

#### Scenario: Disabling sync after it was enabled does not remove local data or function
- GIVEN a device with sync previously enabled and later disabled
- WHEN the user continues using the app
- THEN all local data MUST remain intact and all local features MUST keep
  working

### Requirement: Conflicts are visible in a conflict-history view

The system MUST provide a UI view, reachable from sync settings, listing
entries preserved in `sync_conflicts` (losing revision, timestamp resolved,
originating device) in a form the user can review.

#### Scenario: A resolved conflict appears in the conflict-history view
- GIVEN a sync cycle that resolved a conflict and wrote to `sync_conflicts`
- WHEN the user opens the conflict-history view
- THEN the losing revision, its origin, and resolution time MUST be listed
