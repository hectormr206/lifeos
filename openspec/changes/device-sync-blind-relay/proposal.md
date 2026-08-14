# Proposal: device-sync-blind-relay

Device-to-device sync of the fact graph over the internet, through a VPS relay that only ever holds ciphertext. No VPN required for sync. LifeOS stays fully autonomous on every device; sync is opt-in and additive, never a feature gate.

## Intent

The product promise is the anti-social-network: your whole life in an app, and nothing lives in someone else's cloud being mined. Today the only multi-device story assumes phone and engine share a VPN/LAN segment — the assumption is server-side, in the advertised URLs (`axi/src/axi/dashboard.py:7600-7628`, `_advertised_urls` enumerates VPN/LAN IPv4 only). A future paid tier (sync, encrypted VPS backup, premium features) needs internet sync that keeps us cryptographically unable to read user data. **Honest framing: there is no sync engine anywhere in the repo** — no push, pull, merge, or apply-remote-change; `origin_node` is never written by any INSERT (`axi/src/axi/store.py:1394,1434,4151`). This is greenfield on both `axi/src/axi/store.py` and `mobile/lib/core/graph/`, not a transport swap.

## Decisions encoded (settled — do not re-open)

1. **Retention**: relay is store-and-forward, **delete-on-ack plus 30-day TTL**. "Nothing stays on the VPS" means never plaintext, never permanent, never readable by us — not "holds literally nothing", which only works when both devices are online simultaneously.
2. **Identity**: per-install UUID generated on-device, offline, no server involved. Nickname unique within the user's OWN device set only — a global registry would force server state.
3. **Recovery phrase: mandatory.** 12 words, generated on-device, key-DERIVING (zero-knowledge; never escrowed, no VPS copy — we must remain unable to read data even if compelled). Confirmed at creation by re-entering words. Gated **before sync is enabled, never before local use** — a fresh install works with zero ceremony.
4. **Conflicts**: last-writer-wins by `lamport`, but the losing revision is preserved: written to a local `sync_conflicts` table on the applying device (uuid, losing lamport/origin/payload, resolved_at) and surfaced as a "Conflict history" view under sync settings. Never silently destroyed.
5. **Identity substrate**: build on the existing unused `devices.device_pubkey` / `pubkey_proven` columns (`axi/src/axi/store.py:2886-2897`). Do NOT stretch `mesh_trust.py`'s single-owner mesh model into general device identity — reuse its Ed25519 signing primitives only (`build_signed_payload`/`sign_request`/`verify_request`, `axi/src/axi/mesh_trust.py:595,613,618`).
6. **Relay auth**: Ed25519 signature over the envelope — proves key possession without the VPS learning who the device is.

## Slices (chained PRs, `auto-chain`, 400-line budget each)

### Slice 1 — Device identity + recovery phrase

- **Scope**: on-device UUID + nickname (unique per device set); keypair generation; populate `device_pubkey`/`pubkey_proven`; 12-word phrase generation, confirmation flow, key derivation. Shared domain layer across Android/Linux/Windows/macOS/iOS.
- **Estimate**: 400+ lines — expect sub-slices (key/phrase domain vs. platform wiring). Risk: High (key handling).
- **Why first**: this is the piece with the highest lock-out risk, and it is fully testable and shippable with no relay in existence. Landing it first lets the phrase and key derivation soak on real devices for weeks *before* any synced data depends on them. A key-derivation bug found while the phrase protects nothing is a bad afternoon; the same bug found after a full graph has synced is unrecoverable data loss. Relay-first would leave infrastructure running with nothing to talk to it and would delay the highest-risk code to last.

### Slice 2 — Blind relay service

- **Scope**: new stateless HTTPS service, deployed in Coolify on the VPS with guardrails (resource limits, no host access). Accepts opaque signed envelopes addressed by recipient UUID; verifies the Ed25519 envelope signature; delete-on-ack + 30-day TTL; max envelope size. Stateless and ciphertext-only so it CAN scale later — no sharding, no queue-at-scale, no control plane now.
- **Estimate**: ~350–450 changed lines incl. tests. Risk: Medium.

### Slice 3 — Sync engine on axi

- **Scope**: push/pull change sets from `nodes`/`edges` (the only sync-ready tables — `uuid`/`origin_node`/`lamport`/`deleted_at`, `axi/src/axi/store.py:219-274`); start writing `origin_node`; LWW merge with `sync_conflicts` preservation; envelope encrypt/decrypt; relay client.
- **Estimate**: 400+ lines — expect sub-slices (merge core vs. transport). Risk: High (greenfield merge logic).

### Slice 4 — Sync engine on Flutter

- **Scope**: same engine against the Dart mirror (`mobile/lib/core/graph/local_graph_schema.dart:12-95`, confirmed column parity). Automatic upload/download only on WiFi.
- **Estimate**: 400+ lines — expect sub-slices. Risk: High.

### Slice 5 — UI and connectivity state

- **Scope**: a connectivity state distinct from VPN reachability for `needsPairing` (`mobile/lib/app.dart:155-172`); opt-in sync settings; recovery-phrase ceremony entry point; conflict-history view.
- **Estimate**: ~300–400 lines. Risk: Medium.

## Capabilities

### New Capabilities
- `blind-relay`: stateless ciphertext store-and-forward relay with delete-on-ack + TTL and anonymous Ed25519 envelope auth.
- `device-identity`: per-install UUID, per-device-set nickname, keypair on `devices` pubkey columns.
- `recovery-phrase`: mandatory 12-word key-deriving phrase, gated before sync only.
- `graph-sync`: push/pull/LWW-merge engine for `nodes`/`edges` on axi and Flutter, with conflict preservation.
- `sync-opt-in-ux`: sync settings, connectivity state, conflict history.

### Modified Capabilities
- None (no existing specs in `openspec/specs/`).

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| New relay service (Coolify) | New | blind ciphertext mailbox |
| `axi/src/axi/store.py` | Modified | sync engine, `origin_node` writes, `sync_conflicts` |
| `axi/src/axi/dashboard.py:7600-7628` | Modified | advertise relay-based reachability |
| `mobile/lib/core/graph/` | Modified | Dart sync engine |
| `mobile/lib/app.dart:155-172` | Modified | connectivity state distinct from VPN |
| `axi/src/axi/mesh_trust.py` | Reused | signing primitives only, untouched semantics |

## Non-goals

- **Backups**: stay VPN-only; do not touch `mobile/lib/core/connectivity/reachability_vpn_probe.dart` or `vpn_gate.dart`. A future paid cloud-backup product would contradict the standing "backups never exposed to the internet" rule — that conflict must be raised as its own decision, separately.
- **Social layer**: only requirement is the relay/envelope design must not foreclose it (recipient addressing is already device-UUID based).
- **Scale engineering**: no sharding/queues/control plane; statelessness is the whole scale requirement now.
- **Removing the engine brain**: follow-up change, sequenced after sync exists.
- **Other tables**: meetings, conversations, reminders, chat attachments, domain entries have no sync columns (verified in exploration) — known future scope.

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Greenfield merge logic loses data | High impact | strict TDD; losing revisions preserved in `sync_conflicts`; LWW tested with concurrent-edit fixtures |
| Key/phrase bugs lock users out | High impact | phrase confirmation at creation; phrase gates sync only, local data never at risk |
| Third identity system drift | Med | build only on `devices` pubkey columns; mesh_trust reused as a library |
| Relay leaks metadata (who talks to whom) | Med | envelopes signed anonymously; only recipient UUID visible; document residual metadata honestly in design |
| Slices 2–4 blow the 400-line budget | High | pre-planned sub-slices in tasks phase |

## Rollback Plan

Relay is additive infra — remove the Coolify service; devices fall back to autonomous local operation (sync is opt-in, nothing local depends on it). Slices 2–5 revert per PR; the only schema addition (`sync_conflicts`) is additive and droppable. No existing data shape changes.

## Dependencies

- `sync-over-vpn` slice 3 (uuid/lamport/tombstone schema) — already landed in schema per exploration.
- Slice order: 1 → 2 → 3 → 4 → 5 — **identity and recovery phrase first** (owner's decision, 2026-08-12), then the relay, then the engines, then the UX. Identity has no dependency on the relay and must soak longest; the relay must exist before either sync engine has a target to address.

## Success Criteria

- [ ] Two devices sync `nodes`/`edges` over plain internet with the VPN down, via the relay.
- [ ] Relay stores only ciphertext; envelopes deleted on ack; unacked envelopes expire at 30 days (tests prove all three).
- [ ] VPS operator cannot decrypt any envelope; no key material ever reaches the server.
- [ ] Fresh install works fully with zero sync ceremony; recovery phrase demanded only when enabling sync.
- [ ] Concurrent edits: higher `lamport` wins, losing revision visible in conflict history.
- [ ] Automatic sync transfers run only on WiFi.
