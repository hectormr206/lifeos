# Exploration: device-sync-blind-relay

VPS as a blind ciphertext relay, replacing the VPN-bound "engine brain" transport.

## Current State

### Sync data model (already built by the PR1–PR8 chain, verified in code)

- `axi/src/axi/store.py:219-274` — `nodes` and `edges` carry the sync columns: `uuid`
  (stable id), `origin_node TEXT` (authoring replica, lines 230/272),
  `lamport INTEGER NOT NULL DEFAULT 0` (LWW logical clock, lines 231/273),
  `deleted_at REAL` (tombstone, lines 232/274). `edges` additionally carries
  `src_uuid`/`dst_uuid TEXT NOT NULL` (lines 266-267) resolved from `nodes.uuid`, not
  local rowid — the comment at line 261 confirms a dangling `src_uuid` is legal by
  design, because an edge may sync before its node.
- **Only `nodes` and `edges` carry these columns.** Verified by full-file grep:
  `conversations` (281), `meetings` (305), `meeting_segments` (324),
  `meeting_screenshots` (337), `chat_attachments` (352), `speakers` (368),
  `meeting_speakers` (379), `reminders` (390), `events` (417), `brain_metrics` (430),
  `meta` (445), `domain_node_map` (2814) and `devices` (2886) have no
  `lamport`/`origin_node`/`deleted_at` in their CREATE TABLE bodies. The fact-graph is
  sync-ready; meetings, conversations, reminders, chat attachments and domain entries
  are not.
- **`origin_node` is never written today.** Every `INSERT INTO nodes` / `INSERT INTO
  edges` call site (lines 1394, 1434, 4151) leaves it unset. The column exists in the
  schema; no writer populates it.
- **No sync transport exists anywhere.** Grepping `axi/src/axi` for
  `sync_endpoint|SyncClient|push_changes|pull_changes|/sync/` returns zero real
  matches. The PR1–PR8 chain built the schema and the migration-safety scaffolding
  only — no sync engine, no merge/apply-remote-change logic, no LWW comparison code.
  Consequently the "LWW conflict resolution" reading is a reading of the schema's
  *intent* (a `lamport` column implies LWW), not of any executed merge logic.
- `mobile/lib/core/graph/local_graph_schema.dart:12-95` — the Dart mirror. Exact
  column parity confirmed: `uuid TEXT NOT NULL UNIQUE`, `origin_node TEXT`,
  `lamport INTEGER NOT NULL DEFAULT 0`, `deleted_at REAL` on both `nodes` (55-66) and
  `edges` (73-82), same indexes (`idx_edges_src`, `idx_edges_dst`, `*_deleted`, lines
  90-95). No drift.

### Ed25519 mesh trust (already built — for a different purpose than device sync)

- `axi/src/axi/mesh_trust.py`. `build_signed_payload` (line 595) wraps a body in
  `{body, ts, nonce}` and canonically serializes it (`_canonical`, line 295,
  deterministic JSON). `sign_request` (613) signs those bytes with a node's Ed25519
  private key. `verify_request` (618) and `verify_membership` (526-589) check: the
  cert decodes; the root Ed25519 signature over the canonical cert; that
  `cert.mesh_id == sha256(root_pubkey)` binds the cert to one mesh; expiry (90-day
  default TTL, line 132); and revocation via an injected `is_revoked` callback that
  must be passed explicitly, or the explicit `NO_REVOCATION_CHECK` sentinel (line
  156) — never a silent default.
- Keys live in `root.json` (`_root_path`, line 219) inside `mesh_dir(base_dir)`,
  encrypted with AESGCM under a KEK derived from an owner passphrase via argon2id
  (preferred) or scrypt (`_derive_kek`, line 248). The root private key never touches
  disk in plaintext (`_unlock_root_private_raw`, line 440).
- **What it actually authenticates today**: peer-to-peer *model inference relay*
  between axi engine nodes that already trust each other — `mesh_id` is one
  operator's mesh of their own instances. It is not device-to-VPS sync and not a
  per-device identity system. Confirmed end-to-end call path:
  `mesh_client.infer_peer` (`axi/src/axi/mesh_client.py:47-74`) builds the signed
  payload and POSTs to `{base_url}/api/v1/infer`; `dashboard_mesh_relay`
  (`dashboard.py:765`) and `mesh_infer.py` are the server-side verifier callers (8
  callers of `verify_request`). Genuinely wired and tested (`test_mesh_infer.py`,
  `test_mesh_trust.py`, `test_pair_endpoint.py`) — but for federated LLM inference,
  not blind-relay data sync.
- **A separate, unrelated identity system**: the `devices` table
  (`axi/src/axi/store.py:2886-2897`) is the mobile-pairing registry —
  `device_id TEXT PRIMARY KEY`, `token_hash` (SHA-256 of a bearer token shown once),
  `device_pubkey`, `pubkey_proven`, `revoked_at`. This is what the mobile pairing flow
  uses today, not `mesh_trust.py`. **Two non-overlapping identity systems already
  exist**; a new device-sync identity would be a third unless deliberately unified.

### The VPN assumption — baked in, in two places with different blast radii

1. **Backups (out of scope, confirmed separable).**
   `mobile/lib/core/connectivity/reachability_vpn_probe.dart:60` hardcodes
   `defaultUri = 'http://10.66.66.1:8099/v1/health'` (the WireGuard IP).
   `vpn_gate.dart:14-32` is documented as "the sole authoritative gate for automatic
   backups" and explicitly *not* a general connectivity signal. Different files,
   different providers, `mobile/lib/features/backup/*`. The user's "backups only over
   VPN" constraint is already separable from the sync/engine path in code, not merely
   in principle.
2. **Engine pairing (in scope — the assumption lives in the ADVERTISED URLs, not the
   client).** `mobile/lib/features/connection/data/pairing_repository.dart` and
   `connection_notifier.dart` accept an arbitrary user-supplied `engineUrl`; the
   client has no hardcoded VPN IP. But `axi/src/axi/dashboard.py:7600-7628`
   (`_advertised_urls`, used by the `/setup` QR payload at line 7595) enumerates the
   server's own non-loopback IPv4 interfaces via `ip -4 -br addr` and advertises them
   as `https://{ip}:{port}` — VPN/LAN only (comment at line 7606: "VPN + LAN
   interfaces"). No internet-reachable URL is ever advertised. Today's pairing flow
   therefore assumes phone and engine share a network segment, even though the client
   code is URL-agnostic. A blind relay does not require ripping out client code — only
   changing what gets advertised and how the phone reaches the engine.

- `mobile/lib/app.dart:155-172` (`needsPairing`) — exact gated list: `/chat` (bypassed
  when `localModelEnabledProvider` is true, line 168), `/body`, `/insights`,
  `/briefings`, `/digest`, `/settings/engine`, `/graph*`, `/meetings*`. Already
  ungated (comments at lines 100-114, 147-154): the `/settings` hub, `/reminders`,
  `/domains`, `/mi-vida`. This matches the prior audit exactly; no correction needed.

### "Engine brain" inventory — capability by capability

| Route | Depends on remote engine today | Can plausibly run on-device | Notes |
|---|---|---|---|
| `/graph*` | Yes (pairing-gated) | Yes — the on-device `nodes`/`edges` tables already exist | The sync schema *is* the on-device graph; the remote dependency looks like a data-source wiring choice. Provider wiring not read line-by-line — unverified. |
| `/insights` | Yes — `GET /api/v1/insights/preview` (`insights_screen.dart:8-11`), documented as non-mutating and not synthesizing local domain summaries | Plausible with an on-device model; not verified as implemented | LLM summarization workload, not a hardware limit |
| `/briefings`, `/digest` | Gated per `app.dart:158-159` | Unverified — same summarization category by pattern | Not read line-by-line this pass |
| `/body` | Yes — mirrors `axi/src/axi/organs.py`, the server's own process/service health (`body_screen.dart:8-11`) | **No** — it reports on the laptop's running processes, not user data | Real capability limit |
| `/settings/engine` | Yes, by design — laptop `/config` parity (`app.dart:102-104`) | No — it configures the remote engine | Correctly gated |
| `/meetings*` | Yes — read-only viewer (`app.dart:112-114`) | Source data is laptop-bound: "the phone is not the recorder in v1" (`app.dart:113`) | Capability limit on the *recording*, independent of sync |
| `/chat` | Only when `localModelEnabledProvider` is off | Already has a working on-device path | Proves on-device inference is architecturally viable here |

Net: `/body` and `/settings/engine` are genuine laptop-only capabilities this change
must not try to move on-device. `/meetings` is limited by where recording happens.
`/graph`, `/insights`, `/briefings` and `/digest` look like they could become
on-device-first once the local graph is populated — but that is a plausibility read
from the schema plus the `/chat` precedent, not a confirmed reading of their
provider code.

## Affected Areas

- `axi/src/axi/store.py` — schema exists; needs a sync engine (push/pull,
  apply-remote-change, LWW merge on `lamport`) that does not exist yet. No table other
  than `nodes`/`edges` is sync-ready.
- `mobile/lib/core/graph/local_graph_schema.dart`, `local_graph_store.dart` — the Dart
  counterpart of the same gap.
- `axi/src/axi/mesh_trust.py`, `mesh_client.py` — reusable Ed25519 signing/verification
  primitives, currently scoped to inference-relay trust within one operator's mesh.
- `axi/src/axi/store.py:2886` `devices` — a second, live identity system that a
  relay-based design must fold into or explicitly supersede, or the codebase ends up
  with three parallel identity concepts.
- `axi/src/axi/dashboard.py:7600-7628` (`_advertised_urls`) — the singular place the
  VPN/LAN reachability assumption is encoded for the engine path.
- `mobile/lib/core/connectivity/reachability_vpn_probe.dart`, `vpn_gate.dart` —
  confirmed separate (backups). **Do not touch in this change.**
- `mobile/lib/app.dart:155-172` — the pairing gate. A blind relay changes what
  "connected" means, so this redirect logic and its states need a connectivity state
  distinct from VPN reachability.
- Coolify/VPS hosting — the relay is new server-side infra that must live in Coolify
  with guardrails. No existing relay/queue service was found (not searched
  exhaustively).

## Approaches

### 1. Blind ciphertext relay on the VPS (store-and-forward mailbox)

A small stateless HTTPS service in Coolify that accepts opaque encrypted envelopes
addressed by recipient device UUID, holds them until fetched under a bounded
TTL/size policy (Open Question 1), and never decrypts. Devices push/pull over plain
internet, no VPN.

- **Pros:** matches the stated intent; naturally stateless and partitionable by
  recipient UUID, so the "must be able to scale later" requirement is satisfied for
  free; reuses the canonical-payload-signing primitives for envelope authenticity
  without inheriting the mesh-of-one-operator trust model.
- **Cons:** store-and-forward inherently conflicts with "nothing stays" until a
  retention rule is defined; needs a new concept of which device owns which mailbox;
  needs new sync-engine work on both platforms, since none exists.
- **Effort:** High — bounded by the fact that the crypto primitives already exist.

### 2. Reuse `mesh_trust.py`'s Ed25519 mesh model as device identity

Treat every install as a mesh node under one owner's root key and repurpose the
signed-envelope shape for sync payloads instead of inference requests.

- **Pros:** signing, verification, membership certs, KDF-sealed key storage and the
  revocation hook already exist and are tested; avoids a third identity system.
- **Cons:** the model assumes a single owner enrolling nodes under one root, which
  conflates identity with the owner's mesh boundary. Whether it can cleanly express
  "my nickname/UUID, unique, independent of any other owner's mesh" was not verified
  this pass. It also does not solve transport — it still needs approach 1.
- **Effort:** Medium if the model fits; High if it must be reshaped.

### 3. Extend `devices` + bearer-token pairing to carry a public key and address the relay

Leave `mesh_trust.py` untouched (still inference-relay).

- **Pros:** smallest new-identity footprint — reuses the pairing flow the mobile app
  already drives end to end; `device_pubkey`/`pubkey_proven` (lines 2890-2891) already
  exist and are unused, suggesting this was anticipated.
- **Cons:** `devices` lives in the engine's own DB and is populated by a `/setup` flow
  that assumes phone and engine share a network segment — the exact assumption this
  change removes. The pairing bootstrap must be redesigned so it no longer requires
  reaching the engine directly first.
- **Effort:** Medium — auth interceptor, token store and TLS pinning are reusable.

## Recommendation

Approach 3 for identity, evolving toward approach 1 for transport: keep the `devices`
pubkey columns as the identity primitive (already present, already what the live
pairing UI touches), and build the relay as a new, separate, stateless service. Do not
force `mesh_trust.py`'s single-owner mesh model to double as general device identity —
whether it can even express that shape was outside this pass's budget and is a real
risk. Do not touch `reachability_vpn_probe.dart` / `vpn_gate.dart`.

## Risks

- No sync engine exists at all today. This is greenfield work on both `axi/store.py`
  and the Dart mirror — not a transport swap on top of working sync.
- Two pre-existing, non-overlapping trust/identity systems create real risk of a third,
  incompatible one if the proposal does not explicitly pick and reuse.
- `origin_node` is always NULL in practice. LWW is a schema aspiration, not tested
  behaviour — do not assume it already works.
- The VPN assumption for the engine path lives server-side in URL advertisement, so
  scope is easy to underestimate if one assumes only mobile code changes.
- `/body` and `/settings/engine` are real capability limits, not engine-brain
  overreach — they must not be pulled on-device by mistake in a later change.

## Open Questions (surfaced, not answered)

1. **Retention vs. "nothing stays on the VPS."** The relay must be store-and-forward
   because devices are rarely online simultaneously, yet the stated constraint is that
   nothing persists. No TTL/retention code exists anywhere. Needs an explicit rule:
   TTL, delete-on-ack, max envelope size, and behaviour when a device is offline for
   weeks or months (expiry vs. unbounded growth).
2. **Nickname vs. UUID uniqueness scope.** A per-install UUID can be generated fully
   offline; no code generates a "nickname" anywhere today. Whether a human-readable
   nickname must be globally unique (requiring VPS-side registry state, in tension
   with "nothing stays") or unique only within one user's own device set (no server
   state) is undecided.
3. **Key-loss recovery.** `mesh_trust.py`'s KDF-sealed root key has no recovery-phrase
   or backup mechanism. If that shape is reused for sync keys, losing every device
   means the data is unrecoverable. Acceptable, or is a recovery phrase required?
4. **LWW data-loss surface.** With `lamport` + `origin_node` implying last-writer-wins
   and no merge code to inspect, the actual loss scenarios — two devices editing the
   same node offline, then syncing: which write wins, what happens to the loser — need
   explicit design, not inference from the schema.
5. **Relay-level device authentication.** Does the relay authenticate devices at all
   (open drop-box risk), and if so how, without the VPS learning who is who?
   `sign_request`/`verify_request` are a plausible building block (proving possession
   of a private key without revealing identity, if the cert content stays opaque to the
   relay), but whether `verify_membership`'s mesh-binding is compatible with "a unique
   nickname/UUID per install, never repeated" across multiple independent owners was
   not verified — that is the crux of Open Question 2 as well.

## Scoped out of this change

- The social layer ("conectar con dispositivos de nuestro entorno social"). The design
  must not foreclose it; nothing more.
- Designing for billions of devices now. The only requirement is that the relay stay
  stateless and ciphertext-only so it *can* scale.
- Removing the engine brain. Sequenced after sync exists; inventoried above, not
  planned here.
- Backups. Confirmed architecturally separate and staying VPN-only.

## Ready for Proposal

Yes — with the five open questions above surfaced as explicit decisions the proposal
must make, not defer. The groundwork (schema, signing primitives, pairing UI, TLS
pinning, capability inventory) is real and reusable; the sync engine and the relay
service are greenfield.
