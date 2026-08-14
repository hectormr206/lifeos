# Tasks: device-sync-blind-relay

## Review Workload Forecast

| Field | Value |
|---|---|
| Estimated changed lines | ~4,000-4,800 total across 12 PRs (each kept near/under 400) |
| 400-line budget risk | High (aggregate); per-PR High only on 1a, 3b, 4a (crypto/merge/parity) |
| Chained PRs recommended | Yes |
| Suggested split | 1a→1b→1c→1d→2→3a→3b→3c→4a→4b→4c→5 (design.md Migration/Rollout order) |
| Delivery strategy | auto-chain |
| Chain strategy | pending |

Decision needed before apply: No
Chained PRs recommended: Yes
Chain strategy: pending
400-line budget risk: High

### Suggested Work Units

| PR | Goal | Focused test command | Runtime harness | Rollback boundary |
|---|---|---|---|---|
| 1a | axi wordlist+mnemonic+keys+vectors | `pytest axi/tests/test_sync_vectors.py` | N/A — pure functions | Delete `axi/src/axi/sync/{phrase,keys}.py`; unused |
| 1b | axi device UUID/nickname/pubkey | `pytest axi/tests/test_device_identity.py` | N/A | Revert; `devices` columns stay unused |
| 1c | Dart phrase+key vs. vectors | `flutter test mobile/test/core/sync/sync_vectors_test.dart` | N/A — requires 1a's committed `vectors.json` | Delete Dart module; unused |
| 1d | mobile keystore + phrase UI | `flutter test mobile/test/features/sync/` | On-device: phrase entry/confirm flow | Remove UI entry point; phrase never required pre-sync |
| 2 | relay service + deploy | `pytest relay/tests/` | Coolify staging deploy smoke | Remove Coolify service; devices stay autonomous |
| 3a | axi lamport/origin backfill | `pytest axi/tests/test_store_migration.py -k slice_sync_3a` | N/A — pytest tmp DB, parity reference like sync-over-vpn | Additive/backfill only; no read path depends on it yet |
| 3b | axi merge core + conflicts | `pytest axi/tests/test_sync_merge.py` | N/A — pure functions | Delete `merge.py`; nothing calls it yet |
| 3c | axi envelope+relay client+engine | `pytest axi/tests/test_sync_engine.py` | Two tmp SQLCipher DBs + in-process fake relay | Disable engine wiring; store unaffected |
| 4a | Dart merge core vs. shared fixtures | `flutter test mobile/test/core/sync/merge_test.dart` | N/A | Delete Dart merge; unused |
| 4b | Dart envelope+relay client | `flutter test mobile/test/core/sync/` | Fake relay client | Delete; unused |
| 4c | mobile WiFi-only scheduler | `flutter test mobile/test/features/sync/scheduler_test.dart` | On-device Wi-Fi/cellular toggle | Disable scheduler registration |
| 5 | UX: settings/connectivity/conflicts | `flutter test mobile/test/features/sync/` | Manual: toggle sync on/off on device | Hide settings entry; sync stays opt-in |

## Phase 1a: axi crypto core + shared vectors (High risk — soaks before anything depends on it)

- [ ] 1a.1 RED `test_sync_vectors.py`: mistyped word fails checksum before derivation
- [ ] 1a.2 RED same file: same phrase → identical RK/DK/mailbox-auth pubkeys across runs
- [ ] 1a.3 RED same file: official Trezor BIP-39 vectors pass
- [ ] 1a.4 GREEN `axi/src/axi/sync/phrase.py`: vendored wordlist, encode/decode/checksum
- [ ] 1a.5 GREEN `axi/src/axi/sync/keys.py`: HKDF hierarchy (RK/DK/mailbox-auth seed), Ed25519 keypair-from-seed
- [ ] 1a.6 GREEN generate+commit `shared/sync-test-vectors/vectors.json` (mnemonic↔entropy, HKDF outputs, envelope bytes, signature) — **BLOCKS PR 1c; no Dart crypto code lands before this file exists**

## Phase 1b: axi device identity

- [ ] 1b.1 RED `test_device_identity.py`: UUID generation makes no network call
- [ ] 1b.2 RED same file: reinstall produces a new UUID
- [ ] 1b.3 RED same file: duplicate nickname within one device set rejected; same nickname across different sets allowed
- [ ] 1b.4 RED same file: unproven key not treated as trusted
- [ ] 1b.5 GREEN `axi/src/axi/sync/identity.py`; populate `devices.device_pubkey`/`pubkey_proven`

## Phase 1c: Dart crypto parity (High risk — depends on 1a's vectors.json)

- [ ] 1c.1 RED `mobile/test/core/sync/sync_vectors_test.dart`: load `shared/sync-test-vectors/vectors.json`, assert mnemonic/RK/DK/auth-pubkeys/envelope-bytes/signature match byte-for-byte
- [ ] 1c.2 GREEN `mobile/lib/core/sync/{phrase,keys}.dart` mirroring 1a.4/1a.5 exactly

## Phase 1d: mobile phrase ceremony

- [ ] 1d.1 RED `phrase_ceremony_test.dart`: correct re-entry confirms and accepts the phrase
- [ ] 1d.2 RED same file: incorrect confirmation rejects
- [ ] 1d.3 RED same file: fresh install works with zero ceremony; phrase prompt appears only at sync opt-in
- [ ] 1d.4 GREEN `mobile/lib/features/sync/phrase_ceremony/` + keystore storage (reuse `SecureFileKeyStore` pattern)

## Phase 2: relay service (Medium risk)

- [ ] 2.1 RED `relay/tests/`: well-formed opaque envelope accepted; malformed/interpretable content rejected without storing
- [ ] 2.2 RED same: valid signature accepted anonymously (no device UUID logged); invalid signature rejected
- [ ] 2.3 RED same: deposit to unclaimed mailbox → 404; claim-before-deposit enforced
- [ ] 2.4 RED same: acked envelope not retrievable; unacked <30d still delivered; unacked ≥30d purged by sweep
- [ ] 2.5 RED same: oversized envelope rejected before storage; per-mailbox count/size caps enforced (429)
- [ ] 2.6 RED same: **mailbox claim refreshed on every successful authenticated request, expiry extended 30d**
- [ ] 2.7 RED same: **idle device set (all envelopes acked/expired + claim expired 30d) leaves zero rows — envelope, claim, or otherwise — for that mailbox UUID**
- [ ] 2.8 RED same: two mailboxes of the same device set share no linkable field (distinct, independent-looking auth pubkeys)
- [ ] 2.9 GREEN `relay/` FastAPI app (mailbox claim, deposit, fetch, ack endpoints), Dockerfile, Coolify config
- [ ] 2.10 GREEN hourly + startup sweep: delete envelopes >30d unacked AND claims >30d without an authenticated request

## Phase 3a: axi lamport/origin stamping + backfill (Medium risk — live-DB migration)

- [ ] 3a.1 RED `test_store_migration.py -k slice_sync_3a`: pre-migration parity reference captured (row counts/spot-check), matching sync-over-vpn's pattern
- [ ] 3a.2 RED same: backfill sets `origin_node = local device uuid` on every NULL row, leaves `lamport = 0`, initializes counter to `MAX(lamport)`
- [ ] 3a.3 RED same: migration idempotent on re-run (no-op on already-migrated rows)
- [ ] 3a.4 RED `test_store.py`: every insert path (`add_node`, `add_edge`, similar-to auto-edge, `linkers._safe_insert_edge`, `identity` alias endpoint rewrite) stamps `lamport`+`origin_node`
- [ ] 3a.5 RED: full pre-existing axi suite green after 3a alone (no observable behavior change)
- [ ] 3a.6 GREEN implement backfill migration + write-path stamping in `store.py`; `sync_peer_state`, `sync_applied` DDL

## Phase 3b: axi merge core (High risk — pure domain, no I/O)

- [ ] 3b.1 RED `test_sync_merge.py`: absent locally → insert
- [ ] 3b.2 RED same: higher `(lamport, origin_node)` wins
- [ ] 3b.3 RED same: equal-lamport tiebreak — lexicographically greater `origin_node` wins deterministically
- [ ] 3b.4 RED same: tombstone propagates; stale non-deleted revision never resurrects it
- [ ] 3b.5 RED same: **delete dominates a concurrent edit with a HIGHER lamport (tombstone@5 beats edit@7); losing edit preserved in `sync_conflicts`** — the one deviation from pure LWW
- [ ] 3b.6 RED same: same-origin overwrite is linear propagation, not a conflict row
- [ ] 3b.7 RED same: re-applying the same envelope is a no-op via `sync_applied` dedupe; no duplicate `sync_conflicts` rows
- [ ] 3b.8 RED same: dangling `src_uuid`/`dst_uuid` accepted, resolved once the node arrives
- [ ] 3b.9 GREEN `axi/src/axi/sync/merge.py` (pure functions) + `sync_conflicts` DDL

## Phase 3c: axi envelope + relay client + engine

- [ ] 3c.1 RED `test_sync_engine.py`: envelope seal/open round-trip matches `vectors.json`
- [ ] 3c.2 RED same: cursor(P) starts at -1 so backfilled `lamport=0` rows are included in first sync
- [ ] 3c.3 RED same: cursor advances only on peer echo of applied lamport, never on deposit alone
- [ ] 3c.4 RED same: two-store + fake-relay integration — envelope unacked 30 days then repaired by re-send/echo, no permanent loss
- [ ] 3c.5 GREEN `axi/src/axi/sync/{envelope,relay_client,engine}.py`

## Phase 4a: Dart merge core (High risk — parity)

- [ ] 4a.1 RED `merge_test.dart`: same fixture set as 3b.1-3b.8, incl. delete-dominates-higher-lamport and tiebreak, identical outcomes to axi
- [ ] 4a.2 GREEN `mobile/lib/core/sync/merge.dart` mirroring `merge.py`

## Phase 4b: Dart envelope + relay client

- [ ] 4b.1 RED envelope round-trip against `vectors.json`; relay client claim/deposit/fetch/ack against fake relay
- [ ] 4b.2 GREEN `mobile/lib/core/sync/{envelope,relay_client}.dart`

## Phase 4c: mobile scheduler

- [ ] 4c.1 RED `scheduler_test.dart`: automatic sync waits for WiFi, no transfer over cellular
- [ ] 4c.2 RED same: manual sync permitted regardless of connection
- [ ] 4c.3 GREEN WiFi-only scheduler in `mobile/lib/features/sync/` (workmanager unmetered, backup precedent)

## Phase 5: UX (Medium risk)

- [ ] 5.1 RED `needsPairing` uses relay-reachable state, not blocked by VPN-down
- [ ] 5.2 RED all local features work with sync never enabled; disabling sync after enabling keeps local data/function
- [ ] 5.3 RED a resolved conflict appears in the conflict-history view
- [ ] 5.4 RED residual metadata (recipient UUID, size, timing) disclosed verbatim in sync settings text
- [ ] 5.5 GREEN `mobile/lib/app.dart:155-172` connectivity state; `mobile/lib/features/sync/` settings + conflict-history screen
- [ ] 5.6 GREEN `axi/src/axi/dashboard.py:7600-7628` advertise relay reachability alongside VPN/LAN

## Key Learnings

1. `shared/sync-test-vectors/vectors.json` is a hard cross-PR dependency: PR 1c cannot start until PR 1a commits it.
2. Delete-dominates is the sole deviation from pure LWW and needs its own explicit RED test (3b.5), not folded into the general tombstone case.
3. The relay's only state (envelopes + mailbox claims) shares one 30-day TTL, refreshed on use, swept hourly — the "idle set leaves nothing" scenario is a first-class RED test (2.7).
