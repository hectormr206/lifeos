# Tasks: sync-over-vpn

## Review Workload Forecast

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

- [ ] 2.1 RED: `mobile/test/core/connectivity/vpn_gate_test.dart` — `10.66.66.1:8099/health` reachable → `VpnGateResult.onVpn`
- [ ] 2.2 RED: same file — unreachable/timeout (~2s bound) → `VpnGateResult.offVpn`
- [ ] 2.3 RED: same file — ambiguous/error-not-timeout response → `VpnGateResult.unknown`
- [ ] 2.4 RED: hostile-LAN spoof test — a fake local responder answering at `10.66.66.1:8099/health` with a plausible payload still yields `onVpn` from the gate alone, asserting the test also verifies server identity via `mobile/lib/core/tls/` is invoked before any sealed payload is sent (gate is attempt-only, TLS boundary is the real defense)
- [ ] 2.5 GREEN: create `mobile/lib/core/connectivity/reachability_vpn_probe.dart` — Dio-injected probe, ~2s timeout, no `connectivity_plus`
- [ ] 2.6 GREEN: create `mobile/lib/core/connectivity/vpn_gate.dart` — `VpnGate`, `VpnGateResult {onVpn, offVpn, unknown}`, OS-name-parameterized per `app_platform.dart`
- [ ] 2.7 SPIKE (non-blocking, implementation-time): confirm on-device `TRANSPORT_VPN` readable with `ACCESS_NETWORK_STATE` alone; if confirmed, add as optional pre-check only (never authoritative); if it fails, drop with zero behavior change
- [ ] 2.8 TASK: measure real reachability-probe latency on-VPN and off-VPN timeout behavior on a Pixel device; record the measured numbers (not inference) in `openspec/changes/sync-over-vpn/design.md` Open Questions before Phase 3 fixes the scheduler interval

## Phase 3: PR3 — backup scheduler

- [ ] 3.1 RED: `mobile/test/features/backups/scheduler_test.dart` — `VpnGate.onVpn` + Wi-Fi/unmetered → automatic backup runs
- [ ] 3.2 RED: same file — `offVpn` → backup skipped, visible status row (not just log)
- [ ] 3.3 RED: same file — `unknown` → skipped + loud notification + status surfaced in `/settings/backups/server`
- [ ] 3.4 RED: same file — VPN goes `offVpn` mid-backup → abort, recorded failed, surfaced (not presented as success)
- [ ] 3.5 RED: same file — `onVpn` but off Wi-Fi with heavy payload → waits per `heavy_download_policy.dart`
- [ ] 3.6 RED: same file — user disables automatic backups → no run regardless of VPN state; setting persists across restart
- [ ] 3.7 GREEN: implement scheduler in `mobile/lib/features/backups/` using workmanager (`BriefingBackgroundWork` pattern), `NetworkType.unmetered` constraint, using the interval decided from task 2.8's measurement
- [ ] 3.8 GREEN: implement status surface (skip/undetermined/failed visibility) and settings toggle with persistence

## Phase 4: PR4 — schema slice 3a (additive DDL)

- [ ] 4.1 RED: `axi/tests/test_store_migration.py` — `nodes`/`edges` gain `uuid` (backfilled, UNIQUE), `lamport`, `origin_node`, `deleted_at`; existing rows unaffected in behavior
- [ ] 4.2 RED: same file — full pre-existing test suite still green (no observable behavior change) after 3a alone
- [ ] 4.3 GREEN: implement additive DDL in `store.py:198-222`

## Phase 5: PR5 — schema slice 3b (tombstones, irreversible)

- [ ] 5.1 RED: `test_store_migration.py` — deleting a node sets `deleted_at` (no hard DELETE) and tombstones its edges in the same transaction
- [ ] 5.2 RED: same file — reads filter `deleted_at IS NULL`
- [ ] 5.3 RED: same file — row-count + uuid-mapping verification: N nodes/M edges pre-migration map 1:1 post-migration via audit table
- [ ] 5.4 GREEN: implement delete-path rewrite + read filters + cascade-on-delete application logic in `store.py`
- [ ] 5.5 GATE: confirm PR4 merged and its post-verification passed before opening PR5 (3b is irreversible)

## Phase 6: PR6 — schema slice 3c (guard rails)

- [ ] 6.1 RED: `test_store_migration.py` — migration without a prior verified backup aborts without touching `nodes`/`edges`
- [ ] 6.2 RED: same file — process killed mid-migration; restart resumes safely or restores from pre-migration backup; no undetectable partial state
- [ ] 6.3 RED: same file — restarting is idempotent (no duplicate `uuid` assignment, no duplicate tombstone writes) via `PRAGMA user_version` gate
- [ ] 6.4 GREEN: implement mandatory pre-migration file copy, `PRAGMA user_version` idempotency gate, single-transaction DDL, post-migration verification step

## Key Learnings

1. The design deliberately drops Android `TRANSPORT_VPN` from the critical path because it cannot distinguish a WireGuard tunnel from any commercial VPN.
2. Slice 3b is irreversible and must gate on slice 3a's merge and verification before opening its own PR.
3. Probe latency must be measured on a real Pixel device before the scheduler interval is fixed in code.
4. Hostile-LAN spoofing of the VPN-only address is bounded because payloads seal client-side and the TLS layer verifies server identity.
5. Revocation checks reuse the existing `devices.revoked_at` state and only add a fail-closed callback, not a new revocation mechanism.
