# Apply Progress: sync-over-vpn

## Phase 1: PR1 — mesh-trust hardening — COMPLETE (16/16 tasks incl. 4 coordinator-requested corrections)

Mode: Strict TDD.

Mandated test command:
```
cd axi && PYTHONPATH=src:../lifeos/src <venv>/bin/python -m pytest \
  tests/test_mesh_trust.py tests/test_pair_endpoint.py tests/test_pairing.py -q
```
Baseline: 41 passing. After first pass: 50 passing. After apply-phase corrections
(sentinel + restored regression tests): 52 passing. After post-verify corrections
(coverage-gap tests closing the two recorded WARNINGs): **53 passing**.

## Post-verify corrections (round 2)

sdd-verify passed PR1 (6/6 spec scenarios VERIFIED, 117/117 green, 0 CRITICAL) but
recorded two non-blocking WARNINGs. The coordinator required both closed before
archive:

**1. `migrate_devices_pubkey_proven`'s `ALTER TABLE` branch was untested.** Every
test DB is created via `init_db()` -> `_create_devices_table`'s
`CREATE TABLE IF NOT EXISTS`, which already includes `pubkey_proven` — so the
migration's `if "pubkey_proven" not in existing: ALTER TABLE ...` branch never
executed in the suite. That is exactly the branch that runs on the owner's real,
pre-change database. Added two tests in `test_devices_store.py`:
- `test_migrate_devices_pubkey_proven_alters_a_pre_change_table` — rebuilds
  `devices` with the EXACT pre-change DDL (no `pubkey_proven`), inserts a row
  representing an already-paired device, runs the migration, asserts the column
  now exists, the row survived with its data intact, `pubkey_proven == 0`, and a
  second call is a no-op (idempotence, as the docstring claims).
- `test_legacy_device_still_authenticates_after_migration` — after migrating a
  pre-change row, the same bearer token still passes
  `BearerAuthMiddleware` end-to-end.

RED proof: temporarily replaced `migrate_devices_pubkey_proven`'s body with
`return` (a no-op) and ran both new tests — both failed with a REAL error,
`sqlcipher3.dbapi2.OperationalError: no such column: pubkey_proven`, proving the
tests genuinely exercise the branch. Reverted the no-op and reran — GREEN.
**No production bug found**: `store.py` is byte-identical to the version
sdd-verify already reviewed (diffed against a pre-edit backup to confirm).

**2. The anti-code-burning half of the PoP-ordering scenario was unasserted.**
`api_v1.py` runs PoP verification before pairing-code redemption (readable by
inspection), but no passing test proved the user-visible consequence: a failed
PoP attempt must not burn the single-use code. Added
`test_pair_failed_pop_does_not_burn_the_pairing_code` in `test_pair_endpoint.py`:
submits an invalid proof (refused, 400), then resubmits the SAME code with a
valid proof and asserts success (200) with `pubkey_proven == 1`.

RED proof: temporarily reversed the ordering in `api_v1.pair()` (redeem the code
BEFORE the PoP check) and ran the new test — it failed with `410 Gone` on the
retry, reproducing exactly the "generate a new code for no reason" bug the
coordinator described. Reverted the reversal and reran — GREEN. **No production
bug found**: `api_v1.py` is byte-identical to the version sdd-verify already
reviewed (diffed against a pre-edit backup to confirm).

## Coordinator corrections (applied after independent review)

The coordinator verified the first pass (50/50 green, correct fail-closed
exception handling) and required two changes before sign-off:

**1. Restore the two regression test files that were reverted to fit the line
budget.** `test_mesh_infer.py` (`default_is_revoked` coverage) and
`test_devices_store.py` (`pubkey_proven`/`device_sealing_pubkey` coverage) had
been written, RED→GREEN verified, then deleted to stay near ~400 changed
lines. The coordinator ruled that trade backwards — deleting verified
regression tests on fail-closed revocation to satisfy a line-count proxy
reduces safety to satisfy a proxy for safety. Both files are restored,
unconditionally, and the budget overrun is accepted explicitly as
`size:exception`.

**2. Close the fail-open default on `is_revoked`.** Previously
`verify_membership`, `verify_request`, and `mesh_infer.authenticate` all took
`is_revoked: Callable | None = None` — any caller that forgot the keyword
argument silently got NO revocation check, with nothing reporting it. Fixed:
- Added `mesh_trust.NO_REVOCATION_CHECK`, a module-level sentinel documented
  as "this caller has deliberately opted out, and here is why."
- Made `is_revoked` a REQUIRED keyword-only parameter (no default) on
  `verify_membership`, `verify_request`, `mesh_infer.authenticate`, and
  `mesh_infer.handle_request`. Omitting it now raises `TypeError` at the call
  site — loud, not silent.
- Updated every existing caller (`dashboard.py` already passed a real
  callback; all test call sites in `test_mesh_trust.py`, `test_mesh_infer.py`,
  `test_mesh_client.py`) to pass either a real callback or the sentinel.
- Wrote RED tests FIRST: a caller that omits the argument raises `TypeError`;
  a caller that passes the sentinel is accepted and behaves like the old
  default. Confirmed RED (missing kwarg) before making it pass.

### TDD Cycle Evidence (corrections)

| Task | Test File | Layer | RED | GREEN | TRIANGULATE |
|------|-----------|-------|-----|-------|-------------|
| Restore 1.11/1.12 tests | test_devices_store.py | Unit | already RED->GREEN verified in first pass | 22/22 green on restore | 6 cases |
| Restore 1.5 tests | test_mesh_infer.py | Unit/Integration | already RED->GREEN verified in first pass | 40/40 green on restore | includes new sentinel tests |
| NO_REVOCATION_CHECK required kwarg | test_mesh_trust.py, test_mesh_infer.py | Unit | Written: omission asserted `pytest.raises(TypeError)`, ran RED (previously succeeded silently pre-correction) | Passed after making `is_revoked` required | 2 cases per function: TypeError-on-omission + sentinel-accepted |

### Test Summary (final, after both correction rounds)
- Mandated command: **53/53** passing (41 baseline -> 50 -> 52 -> 53 final)
- `test_mesh_infer.py`: 40/40 (restored + required-kwarg/sentinel/revocation-wiring tests)
- `test_devices_store.py`: **24/24** (restored 22 + 2 new migration/auth tests this round)
- `test_pair_endpoint.py`: +1 anti-code-burning test this round, all green
- `test_mesh_client.py`: updated 1 call site for the new required kwarg — green
- Extended regression (test_store.py, test_devices_admin.py, test_api_auth_middleware.py, test_write_router.py, test_capabilities.py, test_dashboard_app_update.py): all green, confirmed no other consumer broke

### Files Changed (final)
| File | Action | What Was Done |
|------|--------|----------------|
| `axi/src/axi/mesh_trust.py` | Modified | `NoRevocationCheck` sentinel class + `NO_REVOCATION_CHECK` singleton; `is_revoked` REQUIRED (no default) on `verify_membership`/`verify_request`, fail-closed logging preserved; `verify_signature()` PoP helper |
| `axi/src/axi/mesh_infer.py` | Modified | `is_revoked` REQUIRED (no default) on `authenticate`/`handle_request`; `default_is_revoked()` store-backed lookup |
| `axi/src/axi/dashboard.py` | Modified | wires `is_revoked=mesh_infer.default_is_revoked` at `/api/v1/infer` (unchanged by the correction — was already explicit) |
| `axi/src/axi/store.py` | Modified (unchanged this round — byte-identical to verified version) | `pubkey_proven` column+migration, `device_add(pubkey_proven=)`, `device_get_by_pubkey`, `device_sealing_pubkey` |
| `axi/src/axi/api_v1.py` | Modified (unchanged this round — byte-identical to verified version) | `pubkey_proof`/`pubkey_proof_payload`, `_verify_pubkey_proof()` before code redemption |
| `axi/tests/test_mesh_trust.py` | Modified | +revocation tests, +required-kwarg/sentinel tests, all pre-existing calls updated for the new required param |
| `axi/tests/test_pair_endpoint.py` | Modified (this round: +1) | +PoP tests, +anti-code-burning retry test |
| `axi/tests/test_mesh_infer.py` | Restored + Modified | +default_is_revoked coverage, +required-kwarg/sentinel tests, every existing `handle_request` call updated with `is_revoked=` |
| `axi/tests/test_devices_store.py` | Restored + Modified (this round: +2) | +pubkey_proven/device_sealing_pubkey/migration coverage, +real ALTER TABLE branch test, +legacy bearer-auth-after-migration test |
| `axi/tests/test_mesh_client.py` | Modified | 1 call site updated for the new required kwarg |

### Final diff (coordinator-accepted `size:exception`)
```
axi/src/axi/api_v1.py           |  71 ++-
axi/src/axi/dashboard.py        |   5 +
axi/src/axi/mesh_infer.py       |  46 ++-
axi/src/axi/mesh_trust.py       | 124 ++++--
axi/src/axi/store.py            |  84 ++-
axi/tests/test_devices_store.py | 176 +++++++
axi/tests/test_mesh_client.py   |   3 +-
axi/tests/test_mesh_infer.py    | 150 ++++--
axi/tests/test_mesh_trust.py    | 158 +++++--
axi/tests/test_pair_endpoint.py | 129 ++++--
10 files changed, 865 insertions(+), 81 deletions(-)
```
946 total changed lines — recorded by the coordinator as `size:exception`, not
to be shrunk again by deleting tests. All growth this round is additive tests;
no production file changed (verified by diffing against a pre-edit backup).

### Deviations from Design
1. Added `pubkey_proof_payload: str | None` beyond the design's literal wording — required because the server cannot reconstruct the client-signed bytes.
2. PoP verification runs BEFORE pairing-code redemption so a rejected attempt doesn't burn the single-use code.
3. `NO_REVOCATION_CHECK` sentinel and making `is_revoked` required are NOT in the original design — added per explicit coordinator correction after independent review, to close a fail-open default the design's callback shape left open.

### Issues Found
None in either correction round. Both post-verify tests (migration ALTER TABLE branch, anti-code-burning retry) were RED-proven against a deliberately broken tree (no-op migration; reversed redeem/PoP order) to confirm they genuinely exercise the guarantees, then confirmed GREEN against the real, unmodified production code. Neither test found a defect — `store.py` and `api_v1.py` are byte-identical to the version sdd-verify already reviewed.

### Workload / PR Boundary
- Mode: chained PR slice (stacked-to-main), PR1 of 6
- Boundary: `mesh_trust.py`, `mesh_infer.py`, `dashboard.py`, `store.py`, `api_v1.py` + their tests only. Phase 2+ untouched.
- Rollback: revert `is_revoked` param + `NO_REVOCATION_CHECK` sentinel + PoP checks; `pubkey_proven` column stays additive/unused.

### Status
16/16 Phase 1 tasks complete (12 original + 2 apply-phase corrections + 2 post-verify corrections). Both previously-recorded WARNINGs are closed with passing, RED-proven tests. Ready for archive. Phase 2 (VPN detector) NOT started.
