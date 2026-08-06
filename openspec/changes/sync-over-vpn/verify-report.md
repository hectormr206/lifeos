# Verify Report: sync-over-vpn — PR1 (mesh-trust hardening)

## Mode
Strict TDD. Full artifact set present (spec, design, tasks, apply-progress). Verifying Phase 1 only (14/14 tasks checked); Phase 2-6 are pending by design (chained-PR strategy) and are NOT in scope for this verification.

## Test Execution Evidence
Command:
```
cd axi && PYTHONPATH=src:../lifeos/src <venv>/bin/python -m pytest \
  tests/test_mesh_trust.py tests/test_pair_endpoint.py tests/test_pairing.py \
  tests/test_mesh_infer.py tests/test_devices_store.py tests/test_mesh_client.py \
  -q -p no:cacheprovider
```
Result: **117 passed**, 0 failed, exit code 0 (1 unrelated deprecation warning about httpx/starlette). Independently re-run in this session — confirmed, not trusted from the prompt.

## Completeness (tasks.md Phase 1)
14/14 checked. Code inspection confirms each checked task has corresponding implementation and test coverage. No unchecked tasks in Phase 1.

## Spec Compliance Matrix

| # | Scenario | Verdict | Evidence |
|---|---|---|---|
| 1 | Revoked device fails verification within cert validity window | **VERIFIED** | `axi/src/axi/mesh_trust.py:526-589` (`verify_membership`) checks revocation independent of expiry; test `test_revoked_device_fails_verification_within_validity_window` at `axi/tests/test_mesh_trust.py:224-237`, passing. |
| 2 | Revocation re-checked on every call, never cached | **VERIFIED** | `verify_membership` has no memoization/caching state; docstring at `mesh_trust.py:543-544` and comment at `mesh_trust.py:574-575` state re-check-every-call. Test `test_revocation_is_rechecked_every_call_not_cached` at `test_mesh_trust.py:240-257` calls verify twice with a mutable closure flag, passing. |
| 3 | Raising revocation callback fails closed, logs, caught separately from generic tamper/decode except | **VERIFIED** | `mesh_trust.py:556-572` is one `try/except Exception` block for decode/signature/expiry; the revocation call at `mesh_trust.py:576-587` is a **separate** `try/except Exception` that logs via `log.error(...)` before returning `False`. Test `test_is_revoked_callback_raising_fails_closed` (`test_mesh_trust.py:273-288`) asserts `result is False` AND asserts a log record containing "revocation" was emitted at ERROR level — passing. |
| 4 | Pairing without valid PoP refused with a PoP-failure reason | **VERIFIED** | `axi/src/axi/api_v1.py:243-276` (`_verify_pubkey_proof`) raises HTTP 400 with `detail` strings all containing "proof of possession" text on missing/malformed/mismatched/invalid proof. Tests `test_pair_device_pubkey_without_pop_is_refused` and `test_pair_pop_signed_by_wrong_key_is_refused` (`test_pair_endpoint.py:155-164`, `191-206`) assert status 400, `"proof" in detail.lower()`, and `store.device_list() == []` (no device created) — passing. |
| 5 | Already-paired devices are not invalidated | **VERIFIED** | Bearer-token auth (`axi/src/axi/api_auth.py:71-87`, `_valid_device_for_token`) gates only on `token_hash` lookup + `revoked_at is not None`; it never reads `pubkey_proven`. `store.device_add`'s `pubkey_proven` parameter defaults to `False` (`store.py:2663`) so legacy rows are unaffected by pairing logic; migration (`store.py:2622-2640`) backfills existing rows to `pubkey_proven=0` without touching `revoked_at`/`token_hash`. No code path conditions authentication or device validity on `pubkey_proven`. Confirmed by static trace; no test directly re-exercises the ALTER TABLE branch on an old-schema DB missing the column (see WARNING below), but the outcome contract is covered by `test_pre_existing_row_migrated_pubkey_proven_defaults_zero` (`test_devices_store.py:157-172`). |
| 6 | PoP check runs before pairing-code redemption | **VERIFIED** | `axi/src/axi/api_v1.py:299-305` (`pair()`): `_verify_pubkey_proof(body)` is called (and can raise 400) at line 301, strictly before `pairing.redeem_code(body.code)` at line 304. Test `test_pair_device_pubkey_without_pop_is_refused` confirms `store.device_list() == []` after a 400, and `test_pair_code_single_use_second_attempt_rejected` establishes the single-use contract generally; no test directly re-uses a code that was rejected for PoP-failure to prove the code is NOT burned (see WARNING below), but the code ordering itself is unambiguous from source. |

## Correctness / Additional Checks (per verification brief)

- **All `verify_membership`/`verify_request`/`authenticate`/`handle_request` call sites pass a real callback or the `NO_REVOCATION_CHECK` sentinel — enumerated:**
  - `axi/src/axi/mesh_trust.py:643` — internal call inside `verify_request`, forwards caller's `is_revoked` unchanged.
  - `axi/src/axi/mesh_infer.py:206` — inside `authenticate`, forwards caller's `is_revoked` unchanged to `verify_request`.
  - `axi/src/axi/dashboard.py:822-832` — live `/api/v1/infer` route: `mesh_infer.handle_request(..., is_revoked=mesh_infer.default_is_revoked)` — real callback.
  - All test call sites in `test_mesh_trust.py`, `test_mesh_infer.py`, `test_mesh_client.py` pass either `is_revoked=mesh_trust.NO_REVOCATION_CHECK`, a lambda, or a named fake — except two deliberate negative tests (`test_mesh_trust.py:306-325`) that omit the kwarg specifically to assert `TypeError`.
  - `inspect.signature` check re-run independently: `is_revoked` has `Parameter.empty` default (i.e., is a required keyword) on all four of `verify_membership`, `verify_request`, `mesh_infer.authenticate`, `mesh_infer.handle_request` — confirmed via live interpreter call, not inference.
  - **No call site found that skips revocation** (silently or otherwise) — every non-test call site either forwards an already-required `is_revoked` or supplies `mesh_infer.default_is_revoked`.

- **`mesh_infer.default_is_revoked` wired at the LIVE endpoint** — traced `dashboard.py:801` (`@app.post("/api/v1/infer")`) → `dashboard.py:822` (`mesh_infer.handle_request(...)`) → `dashboard.py:832` (`is_revoked=mesh_infer.default_is_revoked`) → `mesh_infer.py:439-454` (`default_is_revoked` reads `store.device_get_by_pubkey(node_pubkey)` and returns `bool(device and device.get("revoked_at") is not None)`). **VERIFIED**, not test-only.

- **Boundary — Phase 2+ untouched:** confirmed via `git diff --stat` and directory listing. Changed files are exactly `axi/src/axi/{mesh_trust,mesh_infer,dashboard,store,api_v1}.py` + their five test files — matches apply-progress.md's declared boundary. `mobile/lib/core/connectivity/` contains only a pre-existing `connectivity_status.dart` (untouched, unrelated to this change); `vpn_gate.dart`/`reachability_vpn_probe.dart` (Phase 2 deliverables) do not exist. `mobile/lib/features/backups/` (Phase 3) does not exist. No `uuid`/`lamport`/`origin_node`/`deleted_at` columns appear anywhere in the `store.py` diff (Phase 4-6 schema slices untouched). **VERIFIED clean.**

- **RED-before-GREEN claims in apply-progress.md vs. tests actually present:** Every test named in apply-progress.md's TDD Cycle Evidence table and file list exists in the tree at the referenced files (`test_mesh_trust.py`, `test_pair_endpoint.py`, `test_mesh_infer.py`, `test_devices_store.py`, `test_mesh_client.py`) and all 117 pass at runtime — this is retrospective confirmation of the GREEN end-state, consistent with the claimed RED→GREEN history, but the actual RED (failing) state before implementation cannot be re-verified from the current tree (git history for these files was not inspected commit-by-commit within this PR since it is uncommitted working-tree state). Documentary claim is plausible and internally consistent; treated as **not independently falsifiable from the current snapshot**, not as a defect.

- **Line-budget note:** 785 total changed lines (704 ins + 81 del per `git diff --stat`), matching apply-progress.md's recorded figure. Per the session preflight, this overrun is a recorded, accepted `size:exception` for PR1 and is NOT flagged as an issue here.

## Design Coherence
- Fail-closed callback design decision matches implementation exactly (mesh_trust.py exception handling, dashboard.py wiring).
- PoP design decision matches implementation: `pubkey_proof`/`pubkey_proof_payload` fields, `verify_signature` reuse of Ed25519 scheme — matches design.md "PoP reuses the existing Ed25519 request scheme".
- `NO_REVOCATION_CHECK` sentinel and required-kwarg hardening are **explicitly documented as deviations from the original design** in apply-progress.md (coordinator-requested correction) — consistent, not a silent drift.
- `pubkey_proof_payload` addition beyond design's literal wording is documented as a deviation with a stated technical reason (server cannot reconstruct client-signed bytes) — reasonable, not flagged.

## Issues

### CRITICAL
None found.

### WARNING
1. The `migrate_devices_pubkey_proven()` ALTER-TABLE branch (the actual old-schema migration code path, `store.py:2637-2640`) is never exercised by a test that starts from a `devices` table genuinely missing the `pubkey_proven` column — `_create_devices_table` always creates the column via `CREATE TABLE IF NOT EXISTS`, so in the test suite the `if "pubkey_proven" not in existing` branch is always False. The behavioral *outcome* (existing rows read back as unproven) is verified, but the migration statement itself is dead code from the test suite's perspective. Recommend an explicit test that creates a pre-migration schema (no `pubkey_proven` column), calls `migrate_devices_pubkey_proven()`, and asserts the column now exists and existing rows read `pubkey_proven == 0`.
2. No test proves the anti-code-burning half of scenario 6 end-to-end (a PoP-rejected request followed by a second, valid attempt with the SAME code succeeding) — the code ordering is unambiguous from source (`api_v1.py:299-305`), and `store.device_list() == []` after a PoP rejection is proof no device was created, but "the code is still usable afterward" is not directly asserted by a passing test.

### SUGGESTION
None beyond the two WARNINGs above.

## Final Verdict
**PASS WITH WARNINGS** — all 6 spec scenarios VERIFIED with runtime test evidence; all "how this change could be wrong" checks from the verification brief came back clean (no revocation bypass, live endpoint correctly wired, PR boundary clean); two non-blocking WARNINGs recommend additional migration/ordering test coverage but do not indicate a functional or security defect in the shipped code.
