# Exploration — sync-over-vpn

Phase: `sdd-explore` · Status: done · Next: `sdd-propose`
Backend: hybrid (Engram topic `sdd/sync-over-vpn/explore` + this file)

## What this change is about

Synchronising LifeOS data between the Pixel, the Linux laptop and the VPS over
the already-configured WireGuard VPN.

Owner constraints, verbatim, treated as requirements:

- "Nunca exponer backups a internet"
- "Solo por VPN"
- "Los backups se deben hacer siempre y cuando estemos conectados al VPN del VPS
  que ya tenemos configurado"
- "todo debe vivir en coolify en mi vps" / "nada suelto en el host"

## The design that already existed

`axi/docs/prd/roadmap-on-device-and-federation.md` (2026-07-19) defines D9 sync
as a sealed-box `K_sync` transport inside a larger federation-mesh roadmap,
phased S2.1 → S4.4. Its own status line says "design / roadmap, no code".

That status is now out of date in one direction and accurate in another.

## What is already built

- `device_pubkey` accepted and stored verbatim at pairing —
  `axi/src/axi/api_v1.py:219-227,257`, `axi/src/axi/store.py:2606,2628-2659`.
- `axi/src/axi/federation.py:62-84` — `node_identity()`, identity helper only.
- **Node trust / mesh membership, built beyond the roadmap doc's date** —
  `axi/src/axi/mesh_trust.py`: Ed25519 root-of-trust enrollment (`enroll_node`),
  membership-cert verification (`verify_membership`, lines 497-536), signed peer
  requests (`build_signed_payload` / `sign_request` / `verify_request`, lines
  542-592), 90-day cert TTL. Tested in `axi/tests/test_mesh_trust.py`.
- Remote inference — `mesh_client.py`, `mesh_infer.py`, `mesh_enroll.py`, tested.
- `GraphDatabaseBackend` seam — `mobile/lib/core/graph/graph_database_backend.dart:1-114`,
  SQLCipher on both mobile and desktop, built anticipating phone↔desktop file
  compatibility.
- Backups: a complete, shipped, **manual** system. `backup-host/` binds
  `10.66.66.1:8099`, seals client-side, never decrypts. Mobile UI at
  `/settings/backups/server`.

## What does NOT exist

Verified by grep, no hits anywhere: sealed-box crypto, an event log / oplog,
`lamport`, `origin_node`, `entity_uuid`, `deleted_at`, tombstones.

`nodes` / `edges` DDL (`axi/src/axi/store.py:198-222`) is unchanged:
`id INTEGER PRIMARY KEY AUTOINCREMENT`, hard `ON DELETE CASCADE`, no `uuid`.

**Phase 4 — the actual data sync, which is what this change means — is unbuilt.**

## Two things that are NOT a foundation for this

**The outbox is not a sync engine.** `mobile/lib/core/outbox/outbox.dart` and
`sync_service.dart:25-82` are a one-directional, single-target queue that
replays the phone's own HTTP mutations to whichever engine is paired. No
conflicts, no merge, no bidirectionality.

**Backups are not sync.** They are a separate manual system with no scheduling
and no explicit VPN-state check — only incidental reachability.

## Gaps found

- **Mobile cannot tell VPN from Wi-Fi.** `axi/src/axi/feet.py:95-127` has a real
  server-side check (`vpn_up` via `ip -br link` on `wglifeos`,
  `vpn_peer_reachable` via ping to `10.66.66.1`). The mobile equivalent does not
  exist: `mobile/lib/core/connectivity/connectivity_status.dart` only tracks
  whether the last call to the paired engine succeeded, which cannot distinguish
  LAN Wi-Fi from VPN. The owner's "solo por VPN" rule is currently unenforceable
  on the device that most needs it.

## Security failure modes specific to this feature

- **No revocation check** in `mesh_trust.verify_membership` (explicit
  `TODO(revocation)`). A stolen phone stays cert-valid for up to 90 days even
  after `device.revoked_at` is set.
- **No proof-of-possession** on `device_pubkey` at pairing — sealed-box payloads
  could be addressed to an attacker-controlled key.
- **Outbox / event-log double-apply** (roadmap R11) unaddressed; needs
  idempotency keys before Phase 4 starts.
- **UUID / tombstone migration is irreversible** and correctness-critical — the
  roadmap says so itself. Highest blast radius in the change.
- **A VPS relay sees peer metadata** even with opaque payloads. "No public
  exposure" is not the same claim as "the VPS learns nothing".

### Resolved during exploration

`backup-host`'s Coolify status was listed as unverified from the repo (its
compose file lacks the `coolify` network and Traefik labels that
`ops/ota/docker-compose.yml:40-52` carries). Verified directly on the VPS: it IS
Coolify-managed — `coolify.managed=true`, `coolify.serviceName=lifeos-backup-host`,
config at `/artifacts/po8wgco08k08wwgss8ccwgw4/backup-host/docker-compose.yml` —
and its storage is the managed volume `dcggww8k0o8c004sss8s4s8c_backups`, not a
host path. It does not violate "nada suelto en el host". The OTA service was the
one that did, and that was fixed separately in `d756b8b0`.

## Genuine forks — these need an owner decision

1. **Sync scope**: whitelist of kinds first, or the full graph.
2. **Merge engine**: hand-rolled event log + per-field last-writer-wins
   (roadmap-recommended), cr-sqlite CRDT, or whole-row LWW.
3. **Owner-passphrase gating** — `mesh_trust.enroll_node` already supports it.
   Required before this feature, or deferred?
4. **Mobile VPN detection**: a real WireGuard-interface check (Android has no
   `feet.py` equivalent) vs. a reachability heuristic to a known VPN-only address.
5. **Idempotency keys** before Phase 4 starts, or accept double-apply risk.

## Settled — no debate needed

VPN-only transport for anything new; reuse `mesh_trust.py` for peer identity;
any new VPS component goes through Coolify, matching `ops/ota`.

## Recommended scope for the proposal

A slice of Phase 4, not all of it. Either:

- (a) VPN-gated backup automation — smallest, reuses the shipped `backup-host`,
  adds the missing mobile VPN-state check; or
- (b) the UUID / lamport / tombstone schema migration in isolation, with no live
  sync yet — the irreversible prerequisite, done alone where it can be reviewed.
