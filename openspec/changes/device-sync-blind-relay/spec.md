# Spec: device-sync-blind-relay

Five new capabilities, each a full spec (no prior `openspec/specs/` entries
for any of them). Canonical files live under `specs/{domain}/spec.md`; this
index summarizes scope and links out.

## Domains

| Domain | File | Scope |
|---|---|---|
| `recovery-phrase` | `specs/recovery-phrase/spec.md` | Mandatory 12-word key-deriving phrase; confirmation at creation; gates sync-enable only, never local use; deterministic reconstruction; no lockout on wrong phrase |
| `device-identity` | `specs/device-identity/spec.md` | Offline per-install UUID; nickname unique within one user's device set; keypair on `devices.device_pubkey`/`pubkey_proven` |
| `blind-relay` | `specs/blind-relay/spec.md` | Opaque ciphertext mailbox, addressed by recipient UUID; Ed25519 anonymous auth; delete-on-ack + 30-day TTL; max envelope size; stateless; residual metadata disclosed |
| `graph-sync` | `specs/graph-sync/spec.md` | Push/pull/LWW merge for `nodes`/`edges` only; `origin_node` written on insert; conflict preservation in `sync_conflicts`; tombstone propagation; dangling edge references; WiFi-only auto-transfer |
| `sync-opt-in-ux` | `specs/sync-opt-in-ux/spec.md` | Connectivity state distinct from VPN reachability; sync strictly additive, never a feature gate; conflict-history view |

## Non-Goals (explicit — no requirements written against these)

- **Backups**: stay VPN-only. This spec set makes no requirement touching
  `mobile/lib/core/connectivity/reachability_vpn_probe.dart` or
  `vpn_gate.dart`.
- **Social layer**: connecting with other users' devices. Out of scope; the
  relay/envelope design must not foreclose it, but no requirement here
  implements it.
- **Scale engineering**: no sharding, queues, or control plane. Statelessness
  (see `blind-relay`) is the entire scale requirement for this change.
- **Removing the engine brain**: sequenced as a future, separate change.
- **Other tables becoming sync-ready**: `conversations`, `meetings`,
  `meeting_segments`, `meeting_screenshots`, `chat_attachments`, `speakers`,
  `meeting_speakers`, `reminders`, `events`, `brain_metrics`, `meta`,
  `domain_node_map` are explicitly out of scope for this change (see
  `graph-sync` Requirement: Only `nodes` and `edges` participate in sync).

## Cross-domain dependency note

`recovery-phrase` and `device-identity` (slice 1) have no dependency on
`blind-relay` (slice 2) and are independently testable/shippable.
`graph-sync` (slices 3-4) depends on both existing (needs a key to encrypt
envelopes with, and a relay to address). `sync-opt-in-ux` (slice 5) depends
on all four.
