# Tasks: sync-over-vpn

## Review Workload Forecast (Phases 1-4, SHIPPED — historical)

> The authoritative forecast for the REMAINING work is the second
> `## Review Workload Forecast` further down, covering the reworked Phases 5-8.
> This one describes the original six-PR split, whose schema half was superseded
> once the mobile schema was found to be the target contract.


| Field | Value |
|-------|-------|
| Estimated changed lines | ~1,700-2,150 total across 6 PRs (each PR kept near/under 400) |
| 400-line budget risk | High (aggregate); per-PR Low-Medium except PR3 |
| Chained PRs recommended | Yes |
| Suggested split | PR1 mesh-trust → PR2 VPN detector → PR3 backup scheduler → PR4 schema 3a → PR5 schema 3b → PR6 schema 3c |
| Delivery strategy | auto-chain |
| Chain strategy | stacked-to-main |

Decision needed before apply: No
Chained PRs recommended: Yes
Chain strategy: stacked-to-main
400-line budget risk: High

### Suggested Work Units

| Unit | Goal | Likely PR | Focused test command | Runtime harness | Rollback boundary |
|---|---|---|---|---|---|
| 1 | Revocation fail-closed + PoP on pair | PR1 (~300-350 lines) | `pytest axi/tests/test_mesh_trust.py -k revocation_or_pop` | N/A — pure unit tests, no live network needed | Revert `is_revoked` param + PoP checks; `pubkey_proven` column stays unused |
| 2 | VpnGate + reachability probe | PR2 (~300-350 lines) | `flutter test mobile/test/core/connectivity/` | N/A — OS-name-parameterized fake Dio, no real VPN needed | Delete `vpn_gate.dart`/`reachability_vpn_probe.dart`, unused by anything yet |
| 3 | Backup scheduler + status surface | PR3 (~350-450 lines, watch budget) | `flutter test mobile/test/features/backups/` | N/A on CI; on-device Pixel run for latency measurement task only | Disable scheduler registration; existing manual backup path untouched |
| 4 | Schema 3a additive DDL | PR4 (~80-120 lines) | `pytest axi/tests/test_store_migration.py -k slice_3a` | N/A — pytest tmp DB | Columns unused; drop-column migration if ever needed |
| 5 | Schema 3b tombstones (irreversible) | PR5 (~200-300 lines) | `pytest axi/tests/test_store_migration.py -k slice_3b` | N/A — pytest tmp DB copy of real schema | None — behavioral, ships only after 4 is merged and verified |
| 6 | Schema 3c guard rails | PR6 (~150-200 lines) | `pytest axi/tests/test_store_migration.py -k slice_3c` | N/A — pytest tmp DB, simulated kill mid-migration | Guard rails are additive safety; revert leaves 3a/3b behavior unchanged |

## Phase 1: PR1 — mesh-trust hardening

- [x] 1.1 RED: `test_mesh_trust.py` — revoked device with unexpired cert fails `verify_membership` (Scenario: revoked-within-validity-window)
- [x] 1.2 RED: `test_mesh_trust.py` — revocation re-checked every call, not cached (verify once OK, revoke, verify again fails)
- [x] 1.3 RED: `test_mesh_trust.py` — `is_revoked` callback raising → `verify_membership` returns `False` and logs (fail-closed)
- [x] 1.4 GREEN: add `is_revoked: Callable[[str], bool] | None` param to `verify_membership`/`verify_request` in `axi/src/axi/mesh_trust.py:497-536`; call after signature/mesh/expiry checks; wrap in try/except → False + loud log
- [x] 1.5 GREEN: wire store-backed lookup (`devices.device_pubkey`+`revoked_at`, `store.py:2606-2721`) into `mesh_infer.authenticate` (`axi/src/axi/mesh_infer.py`) — wired at the live `/api/v1/infer` endpoint (`dashboard.py`) via `mesh_infer.default_is_revoked`
- [x] 1.6 RED: `test_pair_endpoint.py` — pairing with `device_pubkey` and no PoP is refused with a PoP-failure reason
- [x] 1.7 RED: `test_pair_endpoint.py` — pairing with valid PoP (sig over `build_signed_payload({"code","device_pubkey"})`) succeeds
- [x] 1.8 RED: `test_pair_endpoint.py` — pairing with `device_pubkey` omitted is unaffected (legacy path)
- [x] 1.9 GREEN: add `pubkey_proof: str | None` (+ `pubkey_proof_payload: str | None`, needed to carry the exact signed bytes) to `PairRequest`; enforce PoP rule at `axi/src/axi/api_v1.py` (`POST /api/v1/pair`)
- [x] 1.10 GREEN: add `devices.pubkey_proven INTEGER DEFAULT 0` migration in `store.py`; default existing rows unproven
- [x] 1.11 RED: `test_devices_store.py` — pre-existing device row with `device_pubkey` and no PoP is marked unproven post-migration; sealed-box consumer treats unproven as absent (restored to the tree per coordinator review — see 1.13/1.14)
- [x] 1.12 GREEN: implement migration (`store.migrate_devices_pubkey_proven`) + sealed-box unproven guard (`store.device_sealing_pubkey`) from 1.11
- [x] 1.13 (coordinator correction) RED: `test_mesh_trust.py`/`test_mesh_infer.py` — a caller that omits `is_revoked` raises `TypeError`; a caller that passes `mesh_trust.NO_REVOCATION_CHECK` is accepted
- [x] 1.14 (coordinator correction) GREEN: `mesh_trust.NO_REVOCATION_CHECK` sentinel; `is_revoked` made a REQUIRED kwarg (no `None` default) on `verify_membership`/`verify_request`/`mesh_infer.authenticate`/`mesh_infer.handle_request`; all existing callers updated
- [x] 1.15 (post-verify coordinator correction) `test_devices_store.py` — exercise the ACTUAL `ALTER TABLE` branch of `migrate_devices_pubkey_proven` (untested: every test DB is pre-migrated via `CREATE TABLE IF NOT EXISTS`). RED proven by temporarily no-opping the migration (real `OperationalError: no such column`), then GREEN. Also added `test_legacy_device_still_authenticates_after_migration`. No production bug found — `store.py` unchanged from the verified version.
- [x] 1.16 (post-verify coordinator correction) `test_pair_endpoint.py` — assert the anti-code-burning half of the PoP-ordering scenario: invalid proof refused, retry with the SAME code + valid proof succeeds. RED proven by temporarily reversing the redeem/PoP order (retry got 410), then GREEN. No production bug found — `api_v1.py` unchanged from the verified version.

## Phase 2: PR2 — VPN detector

- [x] 2.1 RED: `mobile/test/core/connectivity/vpn_gate_test.dart` — `10.66.66.1:8099/health` reachable → `VpnGateResult.onVpn`
- [x] 2.2 RED: same file — unreachable/timeout (~2s bound) → `VpnGateResult.offVpn`
- [x] 2.3 RED: same file — ambiguous/error-not-timeout response → `VpnGateResult.unknown`
- [x] 2.4 RED: hostile-LAN spoof test — a fake local responder answering at `10.66.66.1:8099/health` with a plausible payload still yields `onVpn` from the gate alone, asserting the test also verifies server identity via `mobile/lib/core/tls/` is invoked before any sealed payload is sent (gate is attempt-only, TLS boundary is the real defense)
- [x] 2.5 GREEN: create `mobile/lib/core/connectivity/reachability_vpn_probe.dart` — Dio-injected probe, ~2s timeout, no `connectivity_plus`
- [x] 2.6 GREEN: create `mobile/lib/core/connectivity/vpn_gate.dart` — `VpnGate`, `VpnGateResult {onVpn, offVpn, unknown}`, OS-name-parameterized per `app_platform.dart`
- [ ] 2.7 SPIKE (non-blocking, implementation-time): confirm on-device `TRANSPORT_VPN` readable with `ACCESS_NETWORK_STATE` alone; if confirmed, add as optional pre-check only (never authoritative); if it fails, drop with zero behavior change
- [ ] 2.8 TASK: measure real reachability-probe latency on-VPN and off-VPN timeout behavior on a Pixel device; record the measured numbers (not inference) in `openspec/changes/sync-over-vpn/design.md` Open Questions before Phase 3 fixes the scheduler interval

## Phase 3: PR3 — backup scheduler

- [x] 3.1 RED: `mobile/test/features/backups/scheduler_test.dart` — `VpnGate.onVpn` + Wi-Fi/unmetered → automatic backup runs
- [x] 3.2 RED: same file — `offVpn` → backup skipped, visible status row (not just log)
- [x] 3.3 RED: same file — `unknown` → skipped + loud notification + status surfaced in `/settings/backups/server`
- [x] 3.4 RED: same file — VPN goes `offVpn` mid-backup → abort, recorded failed, surfaced (not presented as success)
- [x] 3.5 RED: same file — `onVpn` but off Wi-Fi with heavy payload → waits per `heavy_download_policy.dart`
- [x] 3.6 RED: same file — user disables automatic backups → no run regardless of VPN state; setting persists across restart
- [x] 3.7 GREEN: implement scheduler in `mobile/lib/features/backups/` (`automatic_backup_runner.dart`, `workmanager_automatic_backup_work.dart`) using workmanager, `NetworkType.unmetered` constraint composed from `kHeavyDownloadsRequireWiFi`, interval `kAutomaticBackupPollInterval` (a documented, PINNED, NOT-MEASURED placeholder — task 2.8 still open)
- [x] 3.8 GREEN: implement status surface (`AutomaticBackupStatusStore` + `backup_settings_screen.dart`) and settings toggle (`AutomaticBackupSettingsStore`) with persistence
- [x] 3.9 (owner decision received) wire `runAutomaticBackupTask` into `core/background/background_tasks.dart`'s live dispatcher with a REAL `runBackup` callback. **Owner decision**: the sealing passphrase is cached in the platform keystore (`AutomaticBackupPassphraseStore`, reusing `flutter_secure_storage` exactly like `SecureFileKeyStore` — see that class's doc for the full reasoning: a device-holding attacker already has the plaintext, so on-device caching does not weaken what the passphrase actually protects, the sealed archive on the VPS). Captured only when the user turns automatic backups ON (`PassphraseDialog`, confirm:true) and deleted when turned OFF. `AutomaticBackupSettingsStore`'s default flipped `true → false` (enabling now requires capturing a secret, so a fresh install can no longer read "on" with nothing backed up). New `AutomaticBackupOutcome.passphraseUnavailable`, distinct from `failed`/`skippedVpnDown`/`skippedVpnUnknown`, surfaced in the status line. Linux-no-keyring failure (the concrete case that drove this) is fail-loud: `AutomaticBackupPassphraseStore.save` does NOT swallow the `PlatformException`; `backup_settings_screen.dart` catches it, shows an error naming the missing keyring, and does not flip the switch. Periodic task registered/cancelled from the same toggle handler.

## Phase 4: PR4 — schema slice 3a (additive DDL)

- [x] 4.1 RED: `axi/tests/test_store_migration.py` — `nodes`/`edges` gain `uuid` (backfilled, UNIQUE), `lamport`, `origin_node`, `deleted_at`; existing rows unaffected in behavior
- [x] 4.2 RED: same file — full pre-existing test suite still green (no observable behavior change) after 3a alone
- [x] 4.3 GREEN: implement additive DDL in `store.py:198-222`

## SCHEMA Phases (5-8, reworked — supersedes the previous Phase 5/6 below this note)

Phases 1-4 above are DONE and shipped (PR1-PR4). The previous Phase 5/6 plan
(kept below for history, DO NOT execute) undercounted the reader-rewrite and
missed FTS/vec delete sites, the tombstone-before-rebuild ordering gate, and
the in-transaction verified-backup gate. This section is authoritative for
the remaining schema work per `design-schema.md`. Numbering continues PR5-PR8
(design-schema.md's PR5/PR6/PR7/PR8 map 1:1 to Phase 5/6/7/8 below).

### Phase 5: PR5 — Expand (reversible: new columns + dual-write + drift check)

- [x] 5.1 RED: `test_store_migration.py` — `migrate_edge_endpoint_uuids` (new) adds `edges.src_uuid TEXT`, `edges.dst_uuid TEXT`, `edges.updated_at REAL`, `nodes.occurred_at REAL`, backfills `src_uuid`/`dst_uuid` from `nodes.uuid` via `from_id`/`to_id`, backfills `updated_at = created_at`; existing rows' observable behavior unchanged
- [x] 5.2 RED: same file — `edges.relation` exists as `GENERATED ALWAYS AS (kind) VIRTUAL` and always equals `kind` for every existing and newly-inserted row (single storage — proves it cannot drift by construction)
- [x] 5.3 RED: same file — re-running the migration on an already-migrated DB is a no-op (idempotent backfill: only touches rows where `src_uuid IS NULL`, per PR4's pattern)
- [x] 5.4 GREEN: implement `migrate_edge_endpoint_uuids` in `store.py`, following `migrate_nodes_edges_sync_columns`'s existing per-row convergent pattern
- [x] 5.5 RED: `test_store.py` — `add_edge` (`store.py:1281`) dual-writes `src_uuid`/`dst_uuid` alongside `from_id`/`to_id` on insert
- [x] 5.6 RED: same file — the similar-to edge insert (`store.py:2978`) dual-writes `src_uuid`/`dst_uuid`
- [x] 5.7 RED: `test_linkers.py` — `linkers._safe_insert_edge` (`linkers.py:63`) dual-writes `src_uuid`/`dst_uuid`
- [x] 5.8 RED: `test_identity.py` — the alias-merge endpoint rewrite (`identity.py:354-355`, `UPDATE edges SET from_id=...`/`to_id=...`) updates `src_uuid`/`dst_uuid` to the canonical node's uuid in the SAME transaction, not a follow-up step
- [x] 5.9 GREEN: implement 5.5-5.8 dual-writes
- [x] 5.10 RED: `test_store_migration.py` — `verify_edge_endpoint_convergence()` (new) asserts `src_uuid = (SELECT uuid FROM nodes WHERE id = from_id)` and `dst_uuid = (SELECT uuid FROM nodes WHERE id = to_id)` for every live edge; a deliberately-desynced row makes it RAISE
- [x] 5.11 RED: same file — `verify_edge_endpoint_convergence()` RAISES (does not silently pass) if it cannot execute at all (e.g. table missing mid-migration) — per the LifeOS silent-failure rule, a check that cannot run also raises
- [x] 5.12 GREEN: implement `verify_edge_endpoint_convergence()`, called at the end of `migrate_edge_endpoint_uuids` and available standalone for CI/regression use
- [x] 5.13 RED: full pre-existing axi test suite green after PR5 alone (zero observable behavior change — old columns/reads still authoritative)
- [x] 5.14 RED+GREEN (added during apply, not in the original slice): `add_node` assigns `nodes.uuid` at insert time. PR4 added the column and a startup backfill but no insert-time assignment, so every node created between two restarts had `uuid IS NULL` and every edge against it dual-wrote `src_uuid IS NULL` — which `verify_edge_endpoint_convergence()` reports as CONVERGED, since NULL equals NULL. Harmless while nothing reads the column; a silently missing link in the user's memory the moment PR6 resolves edges through `src_uuid`. Closed here rather than in PR6 because PR6 is where it stops being detectable as a schema bug and starts looking like lost data. Two tests: uuid present on insert, and an edge between two freshly-created nodes with NO staged backfill call

### Phase 6: PR6(a/b) — Reader rewrite to `src_uuid`/`dst_uuid`/`relation` (High risk — pre-split)

Design-schema.md flags ~40 SQL sites as High risk and recommends pre-splitting.
Confirmed here: split by file group so each PR stays well under the 400-line
production budget without splitting a single file's join logic across two PRs
(splitting mid-file raises reviewability risk higher than the line count does).

- [x] 6a.1 RED: `test_store.py` — every `store.py` read site that joins/selects via `from_id`/`to_id`/`e.kind` (store.py ~1281, 1321, 1382-1416, 2973-2978, plus any sites 5.1-5.12 did not already touch) is rewritten to `src_uuid`/`dst_uuid`/`e.relation` and returns identical results to the pre-rewrite version on a seeded fixture DB
- [x] 6a.2 RED: `test_forget.py` — `forget.py:211-212` read sites rewritten to `src_uuid`/`dst_uuid`/`relation`, identical results on the seeded fixture
- [x] 6a.3 RED: `test_recall.py` — `recall.py:271-273` read sites rewritten, identical results
- [x] 6a.4 RED: `test_linkers.py` — `linkers.py:44-64` read sites rewritten, identical results
- [x] 6a.5 RED: `test_identity.py` — `identity.py:392,453,501,555-557,596,628,690` read sites rewritten (endpoint-rewrite site 354-355 already dual-writes since PR5; this task is the READ side), identical results
- [x] 6a.6 GREEN: implement 6a.1-6a.5 (PR6a — `store.py`, `forget.py`, `recall.py`, `linkers.py`, `identity.py`)
- [x] 6a.7 RED: full pre-existing axi test suite green after PR6a (old `from_id`/`to_id`/`kind` columns still exist and are maintained by PR5's dual-write, so this PR reverts cleanly)
- [x] 6a.8 (coordinator correction, added post-apply) RED+GREEN: `verify_edge_endpoint_convergence()` names the offending edge in its failure message. Both raise branches interpolated raw sqlite Row objects, so a real production failure read `[<sqlcipher3.dbapi2.Row object at 0x7f...>]` — no edge id, no uuid, no indication of which side was NULL. The guard fired but said nothing, which sends you to a debugger against a database you may not be able to reproduce. Failing loudly is only half the contract; the shout has to be actionable. Two tests assert the message contains `id=<edge id>` and never the substring `Row object`
- [x] 6b.1 RED: `test_dashboard.py` — `dashboard.py:2252-2263,2526-2538,2719-2733,2951-2980` read sites rewritten to `src_uuid`/`dst_uuid`/`relation`, identical results on the seeded fixture (the literal pre-rewrite SQL is carried as an oracle in the test and compared against the endpoint output on the shared `pr6a_graph` fixture + a conversation node)
- [x] 6b.2 GREEN: implement 6b.1 (PR6b — `dashboard.py` only, isolated because it alone was estimated to push PR6 over 400 lines). 108 production lines. Adds `_require_node_uuid` so a uuid-less node cannot answer "no relations" with a 200, and pins `ORDER BY nid` on the neighbour query because that list is truncated at `_NEIGHBORHOOD_CAP`
- [x] 6b.3 RED: full pre-existing axi test suite green after PR6b — 59 store-dependent files against both tree states, failure sets identical (baseline `b72f5cd9` 872 passed/23 failed; PR6b 887 passed/23 failed)
- [x] 6b.4 RED: confirmed `meeting.py`'s store-helper-only usage needed zero rewrite — it contains no `from_id`/`to_id` and no SQL statement against the `edges` table at all. Asserted in `test_meeting_sql_contract.py` (the task named `test_meeting.py`, which does not exist; the repo has `test_meeting_*.py`), including a test that the greps themselves still match the shape they are meant to catch. Note: the task text says "from_id/to_id/kind", but only the EDGE `kind` is being renamed — `nodes.kind` is untouched and meeting.py reads it legitimately, so asserting on a bare `kind` would assert a rename that is not happening

### Phase 7: PR7 — Tombstones (all delete paths; FTS invariant) — MUST merge before Phase 8

Design-schema.md is explicit: the still-present `ON DELETE CASCADE` FK on
`from_id`/`to_id` silently destroys edges on any hard node delete until every
delete path below becomes a tombstone. This phase is a hard precondition for
Phase 8, not a suggestion — see gate task 7.12.

- [x] 7.1 RED: `test_store.py` — `store.py:1321` (`DELETE FROM edges WHERE from_id = ? OR to_id = ?`) becomes `UPDATE edges SET deleted_at=?, updated_at=? WHERE (src_uuid=? OR dst_uuid=?) AND deleted_at IS NULL`, same transaction as the node delete
- [x] 7.2 RED: same file — `store.py:1322` (`DELETE FROM nodes_fts WHERE rowid = ?`) stays a HARD delete (FTS is local derived state, never synced) — this task exists specifically to pin that this is a deliberate keep, not an oversight
- [x] 7.3 RED: same file — `store.py:1325` (`DELETE FROM vec_nodes WHERE node_id = ?`, best-effort) stays a HARD delete, unchanged from today
- [x] 7.4 RED: same file — `store.py:1328` (`DELETE FROM nodes WHERE id = ?`) becomes `UPDATE nodes SET deleted_at=? WHERE id=? AND deleted_at IS NULL`
- [x] 7.5 RED: same file — `store.py:1350` (`delete_edge`, `DELETE FROM edges WHERE id = ?`) becomes a tombstone update
- [x] 7.6 RED: `test_meeting.py` — `meeting.py:881` (race-loser orphan node delete) becomes a tombstone `UPDATE`; `meeting.py:882` (`DELETE FROM nodes_fts WHERE rowid=?`) stays a HARD delete; orphan tombstones are accepted noise per design, assert no crash/log-spam regression
- [x] 7.7 RED: `test_identity.py` — `identity.py:356` (alias-merge loser node delete) becomes a tombstone `UPDATE`; `identity.py:357` (`DELETE FROM nodes_fts`) and `identity.py:359` (`DELETE FROM vec_nodes`) both stay HARD deletes
- [x] 7.8 GREEN: implement 7.1-7.7 tombstone rewrites in `store.py`, `meeting.py`, `identity.py`
- [x] 7.9 RED: `test_store.py` — every existing read path adds `deleted_at IS NULL` to its WHERE clause (nodes and edges); a tombstoned row is invisible to `get_node`, recall, search, and edge traversal
- [x] 7.9b RED (coordinator addition after PR6b): `test_dashboard.py` — the SAME invisibility asserted at the HTTP boundary for all four `dashboard.py` read sites rewritten in PR6b (conversation fact ids, `/api/graph/full`, node detail, node neighborhood). 7.10 already says "the read sites touched in Phase 6", which includes these, but 7.9 named only `test_store.py` — so the store layer could be proven tombstone-aware while a tombstoned memory still renders in the graph browser and in the 3D brain. The endpoints are what the user actually looks at; assert there, not only one layer down
- [x] 7.10 GREEN: implement `idx_nodes_deleted`/`idx_edges_deleted` indexes (mobile parity) and wire `deleted_at IS NULL` into the read sites touched in Phase 6
- [x] 7.11 RED: `test_store.py` — **FTS invariant, RED first**: soft-deleting a node (tombstone path) removes its `nodes_fts` row in the SAME transaction so search cannot return a deleted memory; assert directly by tombstoning a node then querying `nodes_fts` for its rowid and asserting zero results — this is the named worst-case (search returning deleted memories) and was missing from the prior plan
- [x] 7.12 GATE: PR7 (this phase) MUST be merged, its full test suite green, and 7.11's FTS invariant proven BEFORE Phase 8 (PR8, the table rebuild) opens. Rationale, stated explicitly so it cannot be skimmed past: until every hard node delete above is a tombstone, the `ON DELETE CASCADE` FK that Phase 8 removes is still live, and any hard delete that slips through silently destroys edges. This is the same shape as the old plan's 5.5 gate, now sequenced correctly (tombstones-before-rebuild, not additive-DDL-before-tombstones)
- [x] 7.13 RED: `test_identity.py` — convergence check covering `identity.py:354-355`'s endpoint rewrite during alias merges: after a merge, assert every edge's `src_uuid`/`dst_uuid` matches the surviving canonical node's uuid AND no edge still points at the tombstoned loser's uuid (dual-representation drift risk named explicitly in design-schema.md)
- [x] 7.14 RED: `test_store.py` — a dangling edge (endpoint uuid with no live node, legal per mobile's design where an edge may sync before its node) is detected by a loud REPORT-ONLY check, not silently ignored and not a hard failure
- [x] 7.15 RED: full pre-existing axi test suite green after PR7; note in the test that a code-level revert of PR7 would RESURRECT soft-deleted rows (semantically one-way once any real delete has happened, even though the code diff itself reverts cleanly)
- [x] 7.16 (coordinator correction, added post-apply) RED+GREEN: the node tombstone bumps `nodes.updated_at` alongside `deleted_at`, matching the edge tombstone in 7.1. Tasks 7.1 and 7.4 came out asymmetric and design-schema.md shows why — the edge row spells out the full SQL, the node row is a one-word placeholder with an empty cell. An omission, not a decision. Left alone it RESURRECTS DELETED MEMORIES: delete a node at T=100 while its `updated_at` sits at T=10, and a peer that merely EDITED the same node at T=50 carries a later `updated_at`, so under last-writer-wins the edit beats the delete and the memory comes back on the next sync, silently. Nothing observable changes today (the row is invisible to every read after PR7, and there is no sync engine yet), which is exactly why it is cheap now and expensive later. Closed BEFORE PR8 because PR8 is the point of no return and this is a data-semantics defect, not a schema one

### Phase 8: PR8 — THE POINT OF NO RETURN (verified backup + single-transaction table rebuild)

Smallest PR by design — the irreversible step ships with nothing else in the
diff. Depends on Phase 7's gate (7.12).

- [ ] 8.0 GATE (restates 7.12 at the point of use): before any task below runs against a real branch, confirm PR7 is merged into the chain and its suite is green. Do not open PR8 otherwise.
- [ ] 8.1 RED: `test_migration_backup.py` — `VACUUM INTO` snapshot opens successfully WITH the SQLCipher key and all rows are present (asserts the already-measured "restorable" half in CI so a future SQLCipher upgrade that changes this fails loudly, per design-schema.md's VERIFIED section — do NOT re-spike this, only pin it as a regression test)
- [ ] 8.2 RED: same file — the same snapshot opened WITHOUT the key raises (asserts the "stays encrypted" half — a safety backup must not become an unencrypted dump of the whole graph)
- [ ] 8.3 RED: same file — snapshot re-opened with the key and `PRAGMA integrity_check` returns anything other than `ok` aborts the migration before it touches `nodes`/`edges`
- [ ] 8.4 RED: same file — row-count parity check (`nodes`, `edges`, `nodes_fts` snapshot count == live count) plus a sampled `(id, uuid)` spot-check; a deliberately mismatched snapshot aborts the migration
- [ ] 8.5 RED: same file — the backup step is an injected callable on the migration entry point; fake success, fake failure, and a fake corrupt-snapshot (`integrity_check` failure) are all exercisable without a real device or key ceremony
- [ ] 8.6 GREEN: implement the 4-step backup gate (8.1-8.5) as an injected pre-migration callable, ahead of `BEGIN IMMEDIATE`
- [ ] 8.7 RED: `test_store_migration.py` — the rebuild runs `PRAGMA foreign_keys=OFF` → `BEGIN IMMEDIATE` → creates `nodes_new`/`edges_new` to mobile's exact DDL → `INSERT INTO ... SELECT` with explicit `id` copy (never AUTOINCREMENT reassignment) → verifies IN-TRANSACTION while old and new tables coexist → `DROP`/`RENAME` → sets `user_version` → `COMMIT` → `PRAGMA foreign_key_check` → `PRAGMA foreign_keys=ON`
- [ ] 8.8 RED: same file — **in-transaction verification, RED first, as its own explicit step (not an implied part of 8.7)**: row counts equal between old and new tables; `SUM`-based checksums over `uuid`, endpoints, `relation` match; zero NULL `uuid`s in `nodes_new`/`edges_new`; id→uuid mapping intact — all checked BEFORE `DROP`/`RENAME`/`COMMIT`, never after
- [ ] 8.9 RED: same file — a deliberately dropped row during the rebuild makes 8.8's verification RAISE, which rolls back the transaction, leaving the OLD schema fully intact (row-loss detectability, proven by seeding a scenario where a row would be lost and asserting rollback, not just asserting the check function's return value in isolation)
- [ ] 8.10 GREEN: implement 8.7-8.9's rebuild + in-transaction verification
- [ ] 8.11 RED: `test_store_migration.py` — `conversations.node_id`/`meetings.node_id` FKs still resolve correctly post-rebuild (explicit `id` copy preserved them)
- [ ] 8.12 RED: same file — post-rebuild, `nodes.uuid`/`edges.uuid` are `NOT NULL UNIQUE` and `lamport` is `NOT NULL DEFAULT 0` (constraints tightened to mobile's exact DDL, not just column presence)
- [ ] 8.13 RED: same file — post-rebuild, any SQL still referencing `from_id`, `to_id`, or `e.kind` fails with `no such column` at first execution (the silent-mis-assignment failure mode is now a hard error by construction — assert this directly rather than assume it)
- [ ] 8.14 RED: same file — process killed mid-rebuild (simulated raise between `BEGIN IMMEDIATE` and `COMMIT`) leaves the OLD schema intact and unmigrated; restarting is a safe no-op or clean retry gated by `PRAGMA user_version`
- [ ] 8.15 GREEN: implement 8.11-8.14 fixes if any gaps found
- [ ] 8.16 RED: full pre-existing axi test suite green after PR8; explicitly assert recovery from this point forward is restore-from-verified-backup only (no code-level revert path), and that this is documented in the PR description, not just in design-schema.md

## Review Workload Forecast

Covers ONLY the new schema phases (5-8). Production and test lines are
estimated separately because new test files do not show up in `git diff
--stat` against the base and have repeatedly thrown off aggregate-only
estimates in this chain.

| PR | Production lines (est.) | Test lines (est.) | Reversible? | Budget risk |
|---|---|---|---|---|
| PR5 (Expand) | ~180-230 (2 new columns + 1 generated column + backfill fn + 4 dual-write call sites + drift-check fn) | ~220-280 (migration tests, dual-write tests per call site, drift-check pass/raise/cannot-run tests) | Yes — revert PR, extra columns lie fallow | Low |
| PR6a (Reader rewrite: store/forget/recall/linkers/identity) | ~260-340 (mechanical join/name rewrites across ~30 of the ~40 sites) | ~150-200 (fixture-equivalence tests per file, reusing seeded DBs) | Yes | **High** — largest single PR in the chain; mechanical but wide-surface, easy to miss a site |
| PR6b (Reader rewrite: dashboard.py) | ~140-190 (the remaining ~10 sites, isolated because they alone were estimated to push PR6 over 400) | ~80-120 | Yes | Medium — isolated by design specifically to keep 6a under budget |
| PR7 (Tombstones + FTS invariant) | ~150-200 (delete-path rewrites in store.py/meeting.py/identity.py, `deleted_at IS NULL` filter additions, 2 new indexes) | ~200-260 (one RED per delete site, the FTS-invariant test, the identity dual-representation convergence check, the dangling-edge report-only check) | Code reverts cleanly, but reverting RESURRECTS soft-deleted rows — semantically one-way once any real delete has occurred | Medium |
| PR8 (Rebuild — point of no return) | ~90-140 (backup-gate callable + rebuild transaction + in-transaction verification, deliberately kept small and isolated) | ~180-240 (VACUUM INTO both-halves regression, integrity_check failure, row-count mismatch, kill-mid-rebuild, FK/constraint assertions) | No — old columns/constraints gone; recovery is restore-from-verified-backup only | Low — small diff, but the highest-consequence PR in the chain despite the low line count |

**Chained-PR recommendation**: Yes, feature-branch-chain, exactly as design-schema.md Decision 4 lays out: PR5 → PR6a → PR6b → PR7 → PR8, each opened only after its predecessor merges and its suite is green.

**Budget risk**: PR6a is the one PR at real risk of exceeding 400 production lines depending on how much boilerplate each of the ~30 sites needs; if it does, split further by file (e.g. `store.py` alone, then `forget.py`+`recall.py`+`linkers.py`+`identity.py`) rather than loosen the budget.

**Decision needed before apply**: No — the split above already resolves design-schema.md's "pre-split recommended" flag for PR6. No open decision blocks starting PR5.

**Point of no return**: **PR8** is the single PR that is not reversible by a code revert. Everything through PR7 (including the tombstone rewrite) reverts as a code change, even though PR7's revert has the caveat that it resurrects rows that were actually soft-deleted in production between merge and revert. PR8 removes `from_id`/`to_id`/the CASCADE FK and the old column shape entirely in one transaction; from that commit onward, recovery is restore-from-verified-backup only, which is exactly why design-schema.md keeps it the smallest, most isolated PR in the chain.

## Key Learnings

1. The design deliberately drops Android `TRANSPORT_VPN` from the critical path because it cannot distinguish a WireGuard tunnel from any commercial VPN.
2. The tombstone PR (Phase 7) must merge and prove its FTS invariant before the table-rebuild PR (Phase 8) opens, because the still-present `ON DELETE CASCADE` FK silently destroys edges until every hard delete becomes a tombstone.
3. `VACUUM INTO` on SQLCipher was measured directly rather than assumed: the snapshot opens with the same key and stays encrypted without it, so PR8 only needs a regression test, not a spike.
4. A soft-deleted node whose `nodes_fts` row survives lets search return deleted memories, which the reworked plan treats as its own explicit RED task rather than an implied side effect of the tombstone rewrite.
5. `lifeos/src/lifeos/edges.py` operates on a separate database from axi's `memory.db` graph, so it stays out of scope and its own sync status is recorded only as an open question.

---

## Superseded: previous Phase 5/6 plan (kept for history only — DO NOT execute)

The following two phases were the pre-rework plan. They undercounted the
reader-rewrite blast radius, missed the FTS/vec hard-delete sites, and placed
the irreversible rebuild-adjacent work before an explicit tombstone-ordering
gate. Superseded in full by Phases 5-8 above.

### Phase 5 (superseded): PR5 — schema slice 3b (tombstones, irreversible)

- [ ] 5.1 RED: `test_store_migration.py` — deleting a node sets `deleted_at` (no hard DELETE) and tombstones its edges in the same transaction
- [ ] 5.2 RED: same file — reads filter `deleted_at IS NULL`
- [ ] 5.3 RED: same file — row-count + uuid-mapping verification: N nodes/M edges pre-migration map 1:1 post-migration via audit table
- [ ] 5.4 GREEN: implement delete-path rewrite + read filters + cascade-on-delete application logic in `store.py`
- [ ] 5.5 GATE: confirm PR4 merged and its post-verification passed before opening PR5 (3b is irreversible)

### Phase 6 (superseded): PR6 — schema slice 3c (guard rails)

- [ ] 6.1 RED: `test_store_migration.py` — migration without a prior verified backup aborts without touching `nodes`/`edges`
- [ ] 6.2 RED: same file — process killed mid-migration; restart resumes safely or restores from pre-migration backup; no undetectable partial state
- [ ] 6.3 RED: same file — restarting is idempotent (no duplicate `uuid` assignment, no duplicate tombstone writes) via `PRAGMA user_version` gate
- [ ] 6.4 GREEN: implement mandatory pre-migration file copy, `PRAGMA user_version` idempotency gate, single-transaction DDL, post-migration verification step
