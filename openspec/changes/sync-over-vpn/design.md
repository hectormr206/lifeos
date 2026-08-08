# Design: sync-over-vpn (foundation slices)

> ## ⚠️ PARTIALLY SUPERSEDED — read `design-schema.md` for all schema work
>
> **The schema half of this document is history, not instruction.** Everything
> below about slice 3 (`3a`/`3b`/`3c`) was replaced by `design-schema.md`'s
> PR5–PR8, which is what actually shipped. `tasks.md` carries the same note
> above its Phase 5/6 block.
>
> This document is kept unedited in its reasoning — the alternatives it
> rejected and why are still the record of how the decisions were made. What
> is annotated below are the statements that are now FALSE, because a reader
> who trusts them writes code that does not compile or deletes something that
> cannot be recovered. Each one is marked in place with **SUPERSEDED** or
> **CORRECTION**; nothing has been deleted.
>
> The parts that are STILL current and were honoured as written: the
> reachability probe as the only authoritative VPN gate, revocation as an
> injected fail-closed callback, and PoP reusing the Ed25519 request scheme
> ordered before code redemption.

## Technical Approach

Three chained slices per the proposal. The single load-bearing verification this phase owed — Android VPN-detection API specifics — **could not be verified live** (context7 doc tools were unavailable in this session), so the design removes the unverifiable API from the critical path: the authoritative gate is a reachability probe to the VPN-only address, which needs no Android-specific API at all. `TRANSPORT_VPN` becomes an optional optimization behind an implementation-time spike.

## Architecture Decisions

### Decision: Reachability probe is the ONLY authoritative VPN gate

> **CORRECTION (two details differ from what shipped)**: the path is
> `/v1/health`, not `/health` — a real curl against the VPS proved `/health`
> answers 401 and only `/v1/health` answers unauthenticated (pinned by
> `vpn_gate_test.dart`). And the "~2 s bounded" claim was NOT true as first
> written: only `sendTimeout`/`receiveTimeout` were set, which do not start
> counting until a connection exists, so off-VPN the probe could block through
> the full SYN retransmit. It is bounded now because `connectTimeout` is set
> too (verify finding W4).

**Choice**: `GET http://10.66.66.1:8099/health` (backup-host, VPN-only bind) with a bounded timeout (~2 s), via the app's existing `dio`. On-VPN: WireGuard RTT, tens of ms (inference, not measured — measure in slice 2's first PR). Off-VPN: `10.66.66.1` is unroutable → immediate network error or the bounded timeout. Cheap enough to gate a scheduler that fires at most every N minutes.
**Alternatives rejected**:
- `NetworkCapabilities.TRANSPORT_VPN` as authoritative — training knowledge (UNVERIFIED here) says it is readable with only `ACCESS_NETWORK_STATE`, but it provably cannot distinguish OUR WireGuard tunnel from any commercial VPN: it is a transport class, not an interface identity. A coffee-shop VPN would pass it. Even if the API details are confirmed, it can never be the gate. Kept only as an optional pre-check spike (skip the probe when no VPN transport exists); if the spike fails, drop it with zero behavior change.
- `connectivity_plus` — NOT in `mobile/pubspec.yaml` (verified); adding a dependency to answer a question the probe already answers better was rejected.
- Desktop `ip -br link` on `wglifeos` (the `axi/src/axi/feet.py:95-127` approach) — available on Linux desktop via `Process.run`, rejected to keep ONE probe path on both platforms and avoid introducing a subprocess boundary (keeps the threat matrix N/A).
**Spoofing note**: a hostile LAN could answer at `10.66.66.1:8099`. The gate only decides whether to ATTEMPT a backup; payloads seal client-side and backup-host never decrypts, so the worst case is a sealed blob sent to an impostor. Server identity validation reuses `mobile/lib/core/tls/`.

### Decision: Revocation as an injected fail-closed callback

> **CORRECTION (shipped signature differs — this one raises `TypeError`)**:
> there is no `| None` and no default. Coordinator correction 1.14 made the
> kwarg REQUIRED, and "I deliberately have no revocation source" is expressed
> by passing the explicit `mesh_trust.NO_REVOCATION_CHECK` sentinel:
> `verify_membership(cert_token, root_pubkey_hex, *, is_revoked: Callable[[str], bool] | NoRevocationCheck, now=None)`.
> A default of `None` would have let a caller skip revocation by forgetting a
> kwarg — the opposite of fail-closed. `verify_request` threads the same
> required kwarg through.

**Choice**: `verify_membership(cert_token, root_pubkey_hex, *, is_revoked: Callable[[str], bool] | None, now)` — called with `cert.node_pubkey` after signature/mesh/expiry checks; `verify_request` threads it through. Server wiring (`mesh_infer.authenticate`) injects a lookup against `devices.device_pubkey` + `revoked_at` (`store.py:2606-2721` — state already exists; `api_auth.py:85` already enforces it for bearer tokens). If the callback RAISES, verification returns False and logs loudly — a revocation source that cannot be read fails closed, never degrades.
**Alternatives rejected**: signed revocation list distributed to peers (machinery for a multi-verifier mesh that doesn't exist yet); short-lived certs + renewal (doesn't give immediate revocation; touches every enrollment path).

### Decision: PoP reuses the existing Ed25519 request scheme

**Choice**: `PairRequest` gains `pubkey_proof: str | None` — hex Ed25519 signature over `build_signed_payload({"code": code, "device_pubkey": pk})` bytes (`mesh_trust.py:542-557`; client sends the payload bytes alongside so ts/nonce verify). Rule at `api_v1.py:230`: `device_pubkey` without valid proof → 400; neither → legacy pairing unchanged (versioned handshake, nothing breaks).
**Migration for already-paired keys**: add `devices.pubkey_proven INTEGER DEFAULT 0`; existing stored keys stay unproven; any future sealed-box consumer MUST treat unproven keys as absent. Re-proving = re-pair (cheap, owner-local).
**Rejected**: a separate challenge/response endpoint (second scheme, extra round trip; the pairing code is already the freshness token).

### Decision: Slice 3 in three sub-slices (each under the 400-line budget)

> **SUPERSEDED IN FULL by `design-schema.md` (PR5–PR8). Do not execute this
> table.** What shipped instead: PR5 expand (additive sync columns +
> dual-write + drift check), PR6 reader rewrite (reads resolve through
> `src_uuid`/`dst_uuid`/`relation`), PR7 tombstones, PR8 **the full table
> rebuild** to mobile's exact DDL — which drops `edges.from_id`, `edges.to_id`
> and `edges.kind` and removes the `ON DELETE CASCADE`.
>
> **The "Rejected" line below is therefore inverted**: the full table rebuild
> was NOT rejected, it is exactly what PR8 did. The blast radius the rejection
> feared is real and was answered with guard rails this table never had — a
> `VACUUM INTO` snapshot that is verified restorable BEFORE the rebuild
> begins, in-transaction column-by-column verification (including embeddings,
> whose silent loss was the failure this nearly shipped), a `PRAGMA
> user_version` gate, and a hard ordering rule that tombstones land before the
> rebuild. See `design-schema.md` and `apply-progress.md`'s Phase 8 sections.
>
> The "Reversible?" column below is also no longer the shipped answer: from
> PR8's rebuild onward the only rollback is the pre-rebuild snapshot file.

| Sub-slice | Content | Reversible? |
|---|---|---|
| 3a | Additive DDL on `store.py:198-222`: `uuid TEXT` (backfilled + UNIQUE index, same transaction), `lamport INTEGER`, `origin_node TEXT`, `deleted_at REAL` on `nodes`/`edges`. No behavior change. | Yes (columns unused) |
| 3b | Delete paths set `deleted_at`; reads filter `deleted_at IS NULL`; deleting a node tombstones its edges in the same transaction (application-level cascade). `ON DELETE CASCADE` stays in DDL — it simply never fires (SQLite can't drop it without a table rebuild; rows are never DELETEd). Purge/GC is a named follow-up. | No (behavioral) |
| 3c | Guard rails: mandatory pre-migration file copy, `PRAGMA user_version` gate for idempotent re-run, single-transaction DDL (SQLite DDL is transactional), post-migration verification (row counts, `uuid` non-null). | — |

**Rejected**: full table rebuild to remove CASCADE (maximum blast radius for a clause that never fires); doing 3a+3b in one PR (over budget, and 3b is the irreversible part — it deserves its own review).

## Data Flow (slice 2)

    BackupScheduler (workmanager, unmetered constraint)
        │ fires
        ▼
    VpnGate.check() ── ReachabilityVpnProbe ──HTTP──▶ 10.66.66.1:8099/health
        │
        ├─ onVpn   → run existing backup path
        ├─ offVpn  → skip, visible status row (normal wait, like Wi-Fi hold)
        └─ unknown → skip + LOUD: notification + status in /settings/backups/server

`VpnGate` follows the `app_platform.dart` pattern: strategy selected by OS-name parameter, probe takes an injected Dio — testable on a Linux host asserting Android behavior, no real VPN needed. Composition with `heavy_download_policy.dart`: automatic backup requires VPN reachability AND Wi-Fi/unmetered (workmanager `NetworkType.unmetered` constraint — backups don't go through `DownloadTask`, so `requiresWiFi` cannot carry the rule alone).

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `axi/src/axi/mesh_trust.py` | Modify | `is_revoked` param in `verify_membership`/`verify_request`, fail-closed |
| `axi/src/axi/mesh_infer.py` | Modify | inject store-backed revocation lookup in `authenticate` |
| `axi/src/axi/api_v1.py` | Modify | `pubkey_proof` field + PoP verification in `pair` |
| `axi/src/axi/store.py` | Modify | `pubkey_proven` column (slice 1); uuid/lamport/tombstone DDL + delete-path rewrite (slice 3) |
| `mobile/lib/core/connectivity/vpn_gate.dart` | Create | `VpnGate` seam, `VpnGateResult {onVpn, offVpn, unknown}` |
| `mobile/lib/core/connectivity/reachability_vpn_probe.dart` | Create | Dio-injected probe implementation |
| `mobile/lib/features/backups/` | Create/Modify | scheduler (workmanager, per `BriefingBackgroundWork` pattern), status surface |
| `axi/tests/test_mesh_trust.py` | Modify | revocation + PoP tests |
| `mobile/test/core/connectivity/` | Create | gate/probe/scheduler fakes and tests |

## Testing Strategy

| Layer | What | Approach |
|-------|------|----------|
| Unit (axi) | revocation fail-closed (callback raises → False), PoP accept/reject/legacy | `test_mesh_trust.py` style, injected `now` |
| Unit (mobile) | gate three-state, unknown-is-loud, scheduler skip/run | fake `VpnGate`, fake Dio adapter; OS-name parameterized on Linux host |
| Integration (axi) | migration on a copied real-schema DB; interrupted-run re-entry via `user_version` | pytest tmp DB |
| Regression | full existing suite green post-3b (zero behavior change claim) | CI |

## Threat Matrix

N/A — no routing, shell, subprocess, VCS/PR automation, executable-file classification, or process-integration boundary (the desktop subprocess option was explicitly rejected to keep it so).

## Migration / Rollout

Slices 1–2: revert-safe PRs. Slice 3: sub-slices 3a→3b→3c as chained PRs; mandatory pre-migration backup; one-way from 3b onward.

> **SUPERSEDED**: slice 3 shipped as PR5→PR6→PR7→PR8 (`design-schema.md`). The
> one-way point is PR8's rebuild, and the "mandatory pre-migration backup" is
> no longer a human instruction: `migrate_rebuild_graph_tables()` refuses to
> begin without a `VACUUM INTO` snapshot it has itself proven restorable
> (still encrypted, opens with the key, row counts and sampled values agree).
> The snapshot lands beside the live database as
> `memory.db.pre-rebuild-<epoch>.db` and is never deleted automatically.

## Open Questions

- [ ] SPIKE (implementation-time, non-blocking): confirm on-device that `TRANSPORT_VPN` is readable with `ACCESS_NETWORK_STATE` alone; failure drops the pre-check only.
- [ ] Measure real probe latency on-VPN and off-VPN timeout behavior on the Pixel before fixing the scheduler interval.
