# Proposal: sync-over-vpn (foundation slices)

Three chained slices toward Pixel↔laptop↔VPS sync over WireGuard. Actual data sync (sealed-box K_sync transport, event log, merge) is a named follow-up, NOT part of this change.

## Intent

The owner's rules — "nunca exponer backups a internet", "solo por VPN", "todo debe vivir en Coolify" — are partly unenforceable today: mobile cannot distinguish VPN from LAN Wi-Fi, and the mesh-trust path that sync will depend on has two known holes. Fix the prerequisites now, in reviewable slices, before any data moves.

## Slices (chained PRs, in order)

### Slice 1 — Close the two mesh-trust holes

- **Intent**: make `mesh_trust.py` safe to build sync on. Honest framing: today's shipped backups do NOT use this path (they seal client-side; `backup-host` never decrypts), so this fixes a prerequisite, not a live breach.
- **Scope**: (a) revocation check in `verify_membership` (`axi/src/axi/mesh_trust.py:497-536`, existing `TODO(revocation)`) so a revoked device fails verification immediately, not after the 90-day cert TTL; (b) proof-of-possession challenge on `device_pubkey` at pairing (`axi/src/axi/api_v1.py:219-227`) so sealed payloads cannot be addressed to an attacker-controlled key.
- **Non-goals**: no changes to backup-host, no new transport.
- **User-visible outcome**: revoking a device takes effect immediately; pairing rejects keys the device cannot prove it holds.
- **Estimate**: ~250–350 changed lines incl. tests. Fits the 400-line budget. Risk: Low.

### Slice 2 — VPN-gated automatic backups

- **Intent**: enforce "los backups se deben hacer siempre y cuando estemos conectados al VPN" on mobile, where it is currently unenforceable (`mobile/lib/core/connectivity/connectivity_status.dart` only tracks last-call success). Server side already knows how (`axi/src/axi/feet.py:95-127`).
- **Scope**: a mobile VPN-state check plus a scheduler that runs automatic backups only while the check passes; respects the Wi-Fi-only heavy-transfer policy (`mobile/lib/core/network/heavy_download_policy.dart`).
- **Automation exception, made knowingly**: game mode, dictation, and meetings stay user-activated. Automatic backups are the deliberate exception because a backup that only runs when remembered is not a backup — forgetting is exactly the failure it must survive.
- **Silent-failure rule**: if VPN state cannot be determined, the backup does NOT run and the app says so loudly; it never degrades to "probably fine".
- **User-visible outcome**: backups happen on their own at home on VPN; never over the internet.
- **Estimate**: ~300–400 changed lines incl. tests. At budget edge — split detector PR from scheduler PR if the forecast exceeds it. Risk: Medium.

### Slice 3 — UUID / lamport / tombstone schema migration, in isolation

- **Intent**: the irreversible sync prerequisite, done alone so it can be reviewed properly. `nodes`/`edges` DDL at `axi/src/axi/store.py:198-222` today: `INTEGER PRIMARY KEY AUTOINCREMENT`, hard `ON DELETE CASCADE`, no `uuid`.
- **Scope**: add `uuid`, lamport/origin columns, soft-delete tombstones; migration script; no live sync, no event log.
- **Non-goals**: no merge logic, no transport, no idempotency keys (see below).
- **User-visible outcome**: none by design — behavior identical; verified by existing test suite.
- **Estimate**: likely 400+ changed lines (DDL, migration, every code path touching deletes, tests). Expect its own chained sub-slices. Risk: High (irreversible).

## Recommendations on open points (owner review requested)

1. **Mobile VPN detection — recommend reachability to a VPN-only address** (`10.66.66.1`, e.g. backup-host health at `:8099`) as the authoritative gate, with Android's `NetworkCapabilities.TRANSPORT_VPN` as a cheap pre-check only. Rationale: reachability proves the property the rule actually demands (traffic can reach the tunnel-only address); `TRANSPORT_VPN` proves only that *some* VPN is up, and Android sandboxing restricts interface enumeration (since ~Android 11), so a `feet.py`-style `ip -br link` check is not available to an app. Android-API specifics are from training knowledge — verify against current docs in the design phase.
2. **Idempotency keys (roadmap R11) — recommend deferring** with the rest of the sync follow-up. Slice 3 is schema-only; with no event application there is nothing to double-apply. R11 becomes a hard precondition of the sync follow-up, recorded there.

## Capabilities

### New Capabilities
- `mesh-trust-hardening`: revocation enforcement and proof-of-possession in the mesh trust path.
- `vpn-gated-backups`: mobile VPN detection and VPN-only automatic backup scheduling.
- `sync-schema-migration`: UUID/lamport/tombstone schema groundwork with no behavior change.

### Modified Capabilities
- None (no existing specs in `openspec/specs/`).

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `axi/src/axi/mesh_trust.py` | Modified | revocation check in `verify_membership` |
| `axi/src/axi/api_v1.py` | Modified | PoP challenge at pairing |
| `mobile/lib/core/connectivity/` | New/Modified | VPN detector |
| `mobile/` backup scheduling | New | VPN-gated automatic backups |
| `axi/src/axi/store.py` | Modified | schema migration (slice 3) |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Slice 3 migration is irreversible | High impact | isolated slice, backup before migrate, full suite green |
| Android VPN detection assumptions wrong | Med | verify in design; fail loudly if undetectable |
| Slice 2 exceeds 400-line budget | Med | split detector/scheduler PRs |
| PoP breaks existing pairing flow | Low | version the pairing handshake; tests in `axi/tests/test_mesh_trust.py` style |

## Rollback Plan

Slices 1–2: revert the PR; no data shape changes. Slice 3: restore from the pre-migration backup taken as a mandatory migration step; the migration itself is one-way.

## Dependencies

Slice order is the dependency chain: 1 → 2 → 3. Sync follow-up depends on all three plus R11.

## Success Criteria

- [ ] Revoked device fails `verify_membership` immediately (test proves it).
- [ ] Pairing rejects a `device_pubkey` without proof of possession.
- [ ] Automatic backup runs on VPN, refuses off-VPN, and fails loudly when state is unknown.
- [ ] Post-migration: full test suite green, zero user-visible behavior change.
