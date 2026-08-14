# Design: device-sync-blind-relay

Companion: **`design-crypto.md`** owns the full key hierarchy, envelope byte
layout, join flow, and the cross-language test-vector contract (the same split
`sync-over-vpn` used for `design-schema.md`). This document owns the sync
protocol, the relay service, module placement, and sub-slicing. The six
proposal decisions are settled inputs and are not re-argued here.

## Technical Approach

Every device (phones AND the axi engine — the engine is just another device
with a mailbox, per "LifeOS is autonomous") runs the same protocol: derive keys
from the 12-word phrase (design-crypto.md), encrypt per-recipient envelopes,
deposit/fetch them at a blind relay mailbox keyed by device UUID, and merge
with LWW on `lamport`. The crypto+merge core is pure domain code duplicated in
Python (`axi/src/axi/sync/`) and Dart (`mobile/lib/core/sync/`), pinned
byte-for-byte by shared test vectors; only transport/OS wiring differs.

## Architecture Decisions

### Decision: Per-peer cursor on `lamport`, advanced only by peer echo

**Choice**: Each device keeps one monotonic Lamport counter (in `meta` /
mobile equivalent). Local write: `counter += 1; row.lamport = counter;
row.origin_node = my_device_uuid`. On applying a remote row:
`counter = max(counter, remote.lamport)`. Send window for peer P = all
`nodes`/`edges` rows with `lamport > cursor(P)`; `cursor(P)` starts at **-1**
(so backfilled `lamport = 0` rows are included in the first sync) and advances
only when P echoes, inside its own envelopes, the highest lamport it has
durably applied from us. Deposit alone advances nothing.
**Alternatives rejected**:
- *Advance cursor on deposit* — an envelope that expires unacked at 30 days
  silently loses changes forever; the echo rule makes loss self-healing
  (sender keeps re-sending until echoed; merge idempotency makes redundant
  delivery a no-op).
- *Dedicated `change_seq` column / outbox journal* — an extra schema column on
  both platforms and a second ordering concept, when the lamport counter with
  the `max()` receive rule already yields a monotonic local order. Cost of the
  cheaper choice: occasional re-send of rows the peer already has — harmless
  by idempotency, bounded at personal scale.

### Decision: LWW by `(lamport, origin_node)`, delete-dominates, losers preserved

**Choice**: Per row `uuid`: absent locally → insert. Else incoming wins iff
`(lamport, origin_node) > (local.lamport, local.origin_node)` lexicographically
— the equal-lamport tiebreak is the lexicographically **greater
`origin_node`** UUID, deterministic on every device. One deliberate deviation
from pure LWW: if either side has `deleted_at` set, the merged row keeps
`deleted_at` (delete-dominates), so a tombstone can never be resurrected by a
concurrent offline edit with a higher lamport. Whenever the incoming row wins
and `local.origin_node != incoming.origin_node` and content differs, the
losing local revision is written to `sync_conflicts` first (proposal
decision 4). Same-origin overwrite is linear propagation, not a conflict.
Applying the same envelope twice is a no-op: equal `(lamport, origin)` never
wins, and a `sync_applied` dedupe table (env_id, applied_at) short-circuits
re-delivered envelopes before merge, so conflict rows are never duplicated.
**Alternatives rejected**: version vectors (true concurrency detection, but
N-device vector state on every row for a table pair that has exactly
`lamport`/`origin_node` today — schema churn out of proportion; the
origin-differs heuristic over-reports slightly and never under-reports);
tombstone-by-lamport only (permits resurrection — violates the requirement).

`sync_conflicts` (additive, droppable — both platforms):

```sql
CREATE TABLE sync_conflicts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  table_name TEXT NOT NULL,            -- 'nodes' | 'edges'
  uuid TEXT NOT NULL,
  losing_lamport INTEGER NOT NULL, losing_origin TEXT,
  losing_payload TEXT NOT NULL,        -- full JSON row snapshot
  winning_lamport INTEGER NOT NULL, winning_origin TEXT,
  resolved_at REAL NOT NULL
);
```

Edge-before-node arrival needs no handling: dangling `src_uuid` is legal by
design (`axi/src/axi/store.py:261`), reads already tolerate it.

### Decision: Backfill migration for the dead columns

`lamport` is never advanced and `origin_node` never written today
(`axi/src/axi/store.py:1394,1434,4151`). A `user_version`-gated migration (PR4
pattern) backfills `origin_node = local device UUID` on every NULL row, leaves
`lamport = 0` (correct: pre-sync rows have disjoint uuids across devices, so
`0` never competes), initializes the counter to `MAX(lamport)`, and every
write path starts stamping both. **Rejected**: bumping existing rows to
lamport 1 (pointless churn; the `cursor = -1` rule already ships them).

### Decision: Relay is Python + FastAPI + SQLite, claim-before-deposit

**Choice**: New top-level `relay/` service — Python 3.12, FastAPI, one SQLite
file on a Coolify volume. Endpoints (all Ed25519-authenticated per
design-crypto.md §4, signed over the exact transmitted bytes with a
`{ts, nonce}` freshness window as `build_signed_payload` does,
`axi/src/axi/mesh_trust.py:595`):

| Endpoint | Effect |
|---|---|
| `PUT /v1/mailbox/{uuid}` | claim mailbox, registering its auth pubkey |
| `POST /v1/mailbox/{uuid}/envelopes` | deposit (only to a claimed mailbox) |
| `GET /v1/mailbox/{uuid}/envelopes` | fetch pending (owner-signed) |
| `POST /v1/mailbox/{uuid}/ack` | delete envelope by env_id (delete-on-ack) |

TTL sweep: `DELETE WHERE deposited_at < now() - 30d` hourly and at startup.
Abuse bounds: 1 MiB max envelope, 1024 envelopes / 256 MiB per mailbox (429
beyond), IP-rate-limited mailbox creation, deposits to unclaimed mailboxes →
404. Claim-before-deposit plus per-mailbox signatures is what stops the open
drop box. Horizontal scale later = partition by mailbox uuid, deliberately not
built now.

**Claim records expire too.** A mailbox claim (uuid + auth pubkey) is the only
state the relay keeps besides pending envelopes, and it carries the SAME 30-day
TTL, refreshed by any successfully authenticated request for that mailbox. The
same hourly sweep drops expired claims. Without this the claim table becomes a
permanent, pseudonymous census of every device set that ever synced — precisely
the linkable residue this design exists to avoid — while a permanently
claim-free relay would be an open drop box. Expiry-on-idle gives both: an
active set keeps its anti-spam guarantee, an abandoned one leaves nothing.
Accepted consequence: a set idle for over 30 days can find its mailbox UUID
squatted by someone who already knew it. The UUID is 128-bit random, so this
requires prior knowledge, and the impact is denial of delivery — never
disclosure, since a squatter cannot decrypt. Recovery is to claim a fresh UUID
and announce it through the roster.
**Alternatives rejected**: Go (smaller static binary, but a third language the
owner must audit and maintain alone — the team surface is Python+Dart);
embedding in axi's dashboard (the relay must be seizable without any personal
data on it, and must not inherit the engine's trust domain); Postgres (state
is one table of transient blobs).

**Residual metadata — honest statement**: the relay operator, or anyone who
seizes the VPS, sees per mailbox: its UUID, its auth pubkey (random,
pseudonymous), envelope sizes, counts, deposit/fetch timestamps, and source
IPs — enough to infer how many devices a set has, when they are active, and
which IPs they use. Never content, never keys, never names. This exact list is
surfaced verbatim in the sync settings UI (slice 5), not buried.

## Data Flow

    writer (store.py / local_graph_store.dart)
      │ stamps lamport+origin_node
      ▼
    SyncEngine.push ── rows > cursor(P) ──▶ Envelope seal (design-crypto §3)
      │                                        │ HTTPS
      ▼                                        ▼
    SyncEngine.pull ◀── fetch+ack ────── relay mailbox (ciphertext only)
      │
      ▼
    merge: LWW + delete-dominates ──▶ sync_conflicts (losers) + echo cursor

## File Changes

| File | Action | Description |
|---|---|---|
| `axi/src/axi/sync/{phrase,keys,envelope,merge,engine,relay_client}.py` | Create | domain core + transport |
| `axi/src/axi/store.py` | Modify | lamport/origin stamping, backfill migration, `sync_conflicts`, `sync_peer_state`, `sync_applied` |
| `relay/` (new service) | Create | FastAPI app, Dockerfile, Coolify config |
| `mobile/lib/core/sync/` | Create | pure-Dart mirror of the domain core |
| `mobile/lib/features/sync/` | Create | settings, phrase ceremony, conflict history, WiFi-only scheduler (workmanager unmetered, per backup precedent) |
| `mobile/lib/app.dart:155-172` | Modify | connectivity state distinct from VPN (slice 5) |
| `axi/src/axi/dashboard.py:7600-7628` | Modify | advertise relay reachability alongside VPN/LAN URLs (slice 5) |
| `shared/sync-test-vectors/vectors.json` | Create | cross-language golden vectors (design-crypto §5) |

Untouched by constraint: `reachability_vpn_probe.dart`, `vpn_gate.dart`,
`mesh_trust.py` semantics (signing helpers reused as a library only).

## Testing Strategy

| Layer | What | Approach |
|---|---|---|
| Shared vectors | phrase→keys, envelope bytes, mnemonic checksum | one JSON, asserted by pytest AND `flutter test` (design-crypto §5) |
| Unit (both) | merge matrix: insert/win/lose/tie/delete-dominates/idempotent-replay; conflict preservation; cursor echo/rewind | pure functions, fixture row pairs — identical fixture set on both platforms |
| Unit (relay) | claim/deposit/fetch/ack, TTL sweep, size/count limits, bad signature, replayed nonce | FastAPI TestClient, tmp SQLite, injected `now` |
| Integration (axi) | two stores + in-process fake relay: full round trip, offline-30-days expiry repair via echo | pytest tmp SQLCipher DBs |
| Regression | full suites green after each PR | CI |

Strict TDD: RED tests precede every merge rule and every relay bound.

## Threat Matrix

N/A — no routing, shell, subprocess, VCS/PR automation, executable-file
classification, or process-integration boundary. The relay is a new network
service; its abuse bounds are designed above and tested as behavior.

## Migration / Rollout

Slice order (owner's decision 2026-08-12): **identity+phrase → relay → axi
engine → Flutter engine → UX**. Sub-slices, each an autonomous chained PR
under the 400-line budget:

| PR | Content | Risk |
|---|---|---|
| 1a | axi: wordlist asset + mnemonic encode/decode + key hierarchy + **vector generation** | High (crypto) |
| 1b | axi: device UUID/nickname, populate `devices.device_pubkey`/`pubkey_proven` | Low |
| 1c | Dart: phrase+key domain, green against the same vectors | High (parity) |
| 1d | mobile: keystore storage + phrase creation/confirmation flow (domain+UI) | Medium |
| 2 | relay service + deploy (split 2a service / 2b limits+deploy only if over budget) | Medium |
| 3a | axi: lamport/origin stamping + backfill migration + `sync_peer_state`/`sync_applied` | Medium |
| 3b | axi: merge core + `sync_conflicts` + idempotency (pure, no I/O) | High |
| 3c | axi: envelope codec + relay client + push/pull engine + cursor echo | High |
| 4a | Dart: clock+merge core against the shared merge fixtures | High |
| 4b | Dart: envelope codec + relay client (vectors) | Medium |
| 4c | mobile: WiFi-only scheduler + orchestration (automatic sync only on WiFi; manual sync any network) | Medium |
| 5 | UX: opt-in settings, connectivity state, conflict history, metadata disclosure | Medium |

Rollback: relay is removable infra; all schema additions are additive and
droppable; devices remain fully autonomous with sync off. Fresh installs run
with zero ceremony — the phrase gates only the moment sync is enabled.

## Open Questions

- [ ] Relay client TLS: reuse `mobile/lib/core/tls/` pinning against the relay
  cert, or plain WebPKI (envelopes are E2E-encrypted regardless)? Decide in
  PR 4b; default WebPKI.
- [ ] Nickname-uniqueness enforcement point when two devices pick the same
  nickname concurrently (roster LWW resolves the row; UX for the loser lands
  in slice 5).
