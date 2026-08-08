```yaml
schema: gentle-ai.verify-result/v1
evidence_revision: sha256:1b511f7968a30bee1038ddd074729fed7880d30e90ea496930f75fe0fea0bdc4
verdict: fail
blockers: 3
critical_findings: 3
requirements: 10/11
scenarios: 22/24
test_command: cd axi && PYTHONPATH=src:../lifeos/src /tmp/claude-1001/-home-hectormr-dev-gama-lifeos-lifeos-app/fb10227c-4e00-4fd5-aaa6-60bf431b6ab5/scratchpad/axienv/bin/python -m pytest -p no:randomly -q tests/test_mesh_trust.py tests/test_mesh_infer.py tests/test_pair_endpoint.py tests/test_devices_store.py tests/test_store_migration.py tests/test_migration_backup.py tests/test_store.py tests/test_identity.py tests/test_linkers.py tests/test_forget.py tests/test_recall.py tests/test_dashboard.py tests/test_meeting_sql_contract.py tests/test_graph_browser.py
test_exit_code: 0
test_output_hash: sha256:35d60d9b8d444bda7daf5544bc45c47cb9987f12719f1eae2842de2b7f6b5558
build_command: cd mobile && PATH="$HOME/development/flutter/bin:$PATH" flutter test test/core/connectivity test/features/backups
build_exit_code: 0
build_output_hash: sha256:bad5a0023d77b1e6cd752f032964561229fce5dff0cfb056735afa3444995994
```

# Verification Report: sync-over-vpn (full chain, PR1–PR8)

**Change**: sync-over-vpn · **Tree**: `510ca5fc`, working tree clean · **Mode**: Strict TDD, full artifact set
**Verdict**: **FAIL** — 3 CRITICAL, 6 WARNING, 3 SUGGESTION. Nothing here breaks current behaviour or the suite; what fails is the chain's own contract (one unfixed instance of the defect class 7.16 declared must-close-before-PR8, and two invariants whose only proof was a one-off manual rehearsal).

## Completeness

| Check | Result |
|---|---|
| Unticked tasks | 2.7, 2.8 only (owner-only, expected) + the superseded Phase 5/6 block explicitly marked DO NOT EXECUTE |
| Tasks marked `[x]` without code | 0 |
| Tasks marked `[x]` without a covering test | 1 — 7.14 (`report_dangling_edges` never wired to any caller) |

## Test evidence (re-run in this session, not trusted from the prompt)

| Suite | Command | Result |
|---|---|---|
| axi, 14 change-relevant files | `pytest -p no:randomly -q tests/test_{mesh_trust,mesh_infer,pair_endpoint,devices_store,store_migration,migration_backup,store,identity,linkers,forget,recall,dashboard,meeting_sql_contract,graph_browser}.py` | **471 passed, 0 failed**, exit 0, 180.7 s |
| mobile | `flutter test test/core/connectivity test/features/backups` | **35 passed, 0 failed**, exit 0 |

## Spec compliance — 11 requirements / 24 scenarios

| Domain | Req | Scenarios | Status |
|---|---|---|---|
| mesh-trust-hardening | 3 | 7 | 7/7 covered by passing tests |
| vpn-gated-backups | 5 | 11 | 8/11 covered; 3 structural-only (W2, W3) |
| sync-schema-migration | 3 | 6 | 6/6 covered; identity continuity verified in-transaction, but see C2 |

Security constraints — all four enforced in code AND pinned by a test:

| Constraint | Enforcement | Test |
|---|---|---|
| Backups VPN-only, never internet-exposed | `vpn_gate.dart:54-61` reachability-only; probe target is the VPN-only address; no cloud path | `vpn_gate_test.dart:130` pins the probed URI |
| `is_revoked` fail-closed | `mesh_trust.py:576-587` — raising callback → `return False` + `log.error`; no default on the kwarg (`:530`, `:624`) | `test_mesh_trust.py:273`, `:306`, `:317` |
| PoP verified BEFORE code redemption | `api_v1.py:299-305` — `_verify_pubkey_proof` then `pairing.redeem_code` | `test_pair_endpoint.py:209` (retry with the SAME code succeeds) |
| Pre-rebuild snapshot stays encrypted | `store.py:3182-3296` `VACUUM INTO` + `_verify_snapshot` | `test_migration_backup.py:69` (unkeyed open raises) and `:50` (keyed open restores) |

---

## CRITICAL

### C1 — Two node-tombstone sites still do not bump `updated_at`; 7.16 fixed only one of three
- `axi/src/axi/identity.py:418-421` (alias merge) and `axi/src/axi/meeting.py:886-889` (race-loser orphan) write `UPDATE nodes SET deleted_at=? …` with no `updated_at`.
- `store.delete_node` (`store.py:1460`) was corrected by task 7.16 for exactly this reason. The identity site is the worst of the three: the comment at `identity.py:395-397` reasons explicitly about LWW resurrection **for the edges**, bumps `updated_at` on both edge rewrites (`:408`, `:412`), and then misses the node three statements later.
- Consequence once the sync engine lands, in the coordinator's own words: a peer that merely EDITED the merged-away duplicate at T=50 beats a delete stamped `updated_at`=T=10 under last-writer-wins, and **the duplicate person the user merged comes back**. Nothing observable today — which was the argument FOR fixing it before PR8, not against.
- No test. `test_store.py:856` pins the invariant only for `store.delete_node`; `test_store.py:977` only for `delete_edge`.

### C2 — The rebuild preserves embeddings only by construction; nothing in CI pins it
- `_rebuild_verify` (`store.py:3487-3515`) compares `uuid, kind, label, data, created_at, deleted_at` for nodes. It does **not** compare `embedding`, `embedding_model`, `embedding_dim`, `occurred_at`, `domain`, `created_tz`, `updated_at`, `origin_node`, `lamport`.
- The `pre_pr8_graph` fixture (`axi/tests/conftest.py:522-597`) seeds **no embedding at all**; `rg embedding axi/tests/test_store_migration.py` returns one comment and zero assertions.
- This is precisely the failure the coordinator caught by hand ("copying mobile's DDL verbatim would have deleted every embedding in the graph — recall and the whole RAG path — with no error and no failing test"). The catch was made once, in a worktree rehearsal that no longer runs. Any future edit to `_NODES_REBUILT_DDL` or `_rebuild_copy_rows` drops every vector on the next un-migrated database with a fully green suite and no in-transaction guard to raise.

### C3 — `report_dangling_edges` is dead code in production
- Defined at `store.py:3095-3153`, referenced only by comments (`store.py:255`, `:3342`) and by tests. `rg report_dangling_edges --glob '*.py' | grep -v tests/` finds **zero call sites**.
- Task 7.14 is marked `[x]` and claims a dangling edge "is detected by a loud REPORT-ONLY check, not silently ignored". In production it is still silently ignored — the check exists but never runs. After PR8 removed the `ON DELETE CASCADE` FK, application-level referential integrity is the only integrity there is, and this is the only thing that would have reported its breaches.

---

## WARNING

### W1 — The Wi-Fi-only rule's real enforcement point has no test, and fails silently
- `background_tasks.dart:120` hardcodes `isOnUnmeteredNetwork: () async => true`, so the runner's Wi-Fi branch (`automatic_backup_runner.dart:112`) is **unreachable in production**. The rule is actually enforced by `Constraints(networkType: kHeavyDownloadsRequireWiFi ? unmetered : connected)` in `workmanager_automatic_backup_work.dart:46-50`.
- `workmanager_automatic_backup_work_test.dart` asserts only two constants; it never constructs `WorkmanagerAutomaticBackupWork` or uses its `Workmanager?` injection seam. Changing `unmetered` → `connected` leaves the entire suite green and ships automatic backups over mobile data.
- `schedule()` and `cancel()` both `catch (_) {}` (`:53`, `:62`). A registration that never lands means automatic backups never run and nothing surfaces — the repo's "a check that cannot run must fail loudly" rule applied to the scheduler's own installation.

### W2 — "Home Wi-Fi with LAN engine reachable" scenario has no covering test
`specs/vpn-gated-backups/spec.md:32-37`. True structurally (the gate takes no engine-reachability input), and `vpn_gate_test.dart:130` pins the probed URI, but nothing fails if someone later adds an engine-reachability fallback to `VpnGate.check`.

### W3 — "Unrelated commercial VPN active" scenario has no covering test
`specs/vpn-gated-backups/spec.md:39-44`. Nothing pins the deliberate absence of `NetworkCapabilities.TRANSPORT_VPN` / `connectivity_plus`. The `operatingSystem` field exists precisely as the seam for task 2.7 to attach a pre-check to — the moment it does, this requirement has no guard.

### W4 — The "~2 s bounded" probe is not bounded
- `reachability_vpn_probe.dart:69-76` sets `sendTimeout`/`receiveTimeout` but **not** `connectTimeout`, and `background_tasks.dart:109` injects a bare `Dio()` whose `connectTimeout` defaults to null = no limit. dio 5.10's per-request `Options` does support `connectTimeout` (`options.dart:227,247`), so this is an omission, not a platform limit.
- On a network with no route to `10.0.0.0/8` the connect fails fast; on any network that routes 10/8 to the default gateway (carrier CGNAT, hotels, many corporate LANs) the SYN goes nowhere and the probe blocks through the full TCP retransmit sequence — ~2 minutes, not 2 seconds.
- Three places assert the bound as fact: `reachability_vpn_probe.dart:49-54`, `workmanager_automatic_backup_work.dart:17-18` ("a handful of ~2s-bounded failed probes a day", the justification for the 6 h interval), and `design.md:11`. The tests use a fake adapter that throws `receiveTimeout`, so none of them exercises the connect phase. Task 2.8 is the measurement that would have caught it.

### W5 — Stale comments asserting the pre-PR8 world, on the point-of-no-return path
- `store.py:1162-1163` — "Dual-written by every edge-insert path from here on; from_id/to_id/kind stay fully authoritative until PR6 (the reader rewrite)." False twice over, and it sits **eleven lines above** the `migrate_rebuild_graph_tables()` call that dropped those columns.
- `store.py:2918-2920` — "PURELY ADDITIVE and reversible: `from_id`/`to_id`/`kind` remain fully authoritative and nothing reads the new columns yet — that is PR6, the reader rewrite." False, and directly contradicted by that same function's own body at `:2984-2989` ("After PR8's rebuild there is no `from_id`/`to_id` to backfill FROM").
- `store.py:3010-3014` — `verify_edge_endpoint_convergence`'s summary line still presents the `from_id`/`to_id` drift comparison as the function's contract and calls the dropped columns "the old authoritative ones". The correction exists, but only as an inline comment 30 lines below (`:3040-3047`), where a reader skimming the docstring will not meet it. Post-rebuild this function checks NULL endpoints only.

### W6 — `design.md` was never marked superseded and still rejects what PR8 shipped
`tasks.md:84-91` carries an explicit supersession note; `design.md` carries none.
- `design.md:29-37` still presents slices 3a/3b/3c and states under **Rejected**: "full table rebuild to remove CASCADE (maximum blast radius for a clause that never fires)". PR8 performed exactly that rebuild and removed exactly that CASCADE.
- `design.md:20` still documents `is_revoked: Callable[[str], bool] | None`; coordinator correction 1.14 removed the `None` default and made the kwarg required. A reader who trusts `design.md` writes a call site that raises `TypeError`.

---

## SUGGESTION

- **S1** — `_verify_snapshot` (`store.py:3254-3258`) spot-checks `ORDER BY id LIMIT 25`: the 25 **oldest** rows. A torn copy loses the tail, which row-count parity catches but value-level sampling never inspects. A random or head+tail sample costs nothing.
- **S2** — `api_v1.py:264-274` validates the PoP envelope's `body` but ignores its `ts`/`nonce`. `build_signed_payload` embeds them specifically for replay defence. Bounded today by the single-use, 5-minute pairing code, so this is defence-in-depth left on the table, not a hole.
- **S3** — `store.py:3282` writes `memory.db.pre-rebuild-<epoch>.db` next to the live DB and never removes it. Correct (it is the entire rollback plan), but it permanently doubles the on-disk footprint and nothing tells the user it exists or when deleting it is safe.

---

## What has NOT been exercised — specific production gaps

1. **A real SQLCipher database with embeddings has never been through the rebuild.** The coordinator's rehearsal used a synthetic 4-node/3-edge legacy DB with one 2048-byte embedding; the automated fixture has none (C2). The user's real graph has thousands.
2. **Disk exhaustion during `VACUUM INTO`.** The snapshot needs free space equal to the whole DB. On failure `MigrationBackupError` propagates through `init_db()` (`store.py:1174`) uncaught — **the daemon does not start**. Correct fail-loud behaviour, never rehearsed, and the user will meet it as "axi is dead" rather than "free some disk".
3. **The rebuild has never run under concurrent writers.** `BEGIN IMMEDIATE` is correct, but every test drives a single-threaded connection; a real startup races the recorder, wakeword and write-router threads.
4. **The VPN probe has never touched a real network.** Every test uses a fake dio adapter (W4). On-VPN latency, off-VPN timeout shape and battery cost are all inferences (tasks 2.7/2.8).
5. **`runBackup` mid-flight VPN loss is simulated by a thrown exception, never by an actual dropped tunnel.** Whether a partially-uploaded archive is left on backup-host is untested at both ends.
6. **No automatic backup has ever completed end to end on a device** — the keystore passphrase capture, the WorkManager registration, and the seal+upload have only run against fakes.
7. **`create_vec_nodes_table` after the rebuild is best-effort** (`store.py:3602-3608`). If sqlite-vec is unloadable at that moment the trigger stays missing for the rest of the process. Low impact (PR7 made deletes tombstones, so the trigger no longer fires and `delete_node` clears `vec_nodes` explicitly), but it is a silent degradation on the irreversible path.

## Before this runs against the user's real database, a human must

1. Close C1 (`identity.py:418`, `meeting.py:886`) — it is free now and data-shaped later, the same argument that made 7.16 mandatory before PR8.
2. Add an embedding to `pre_pr8_graph` and an embedding comparison to `_rebuild_verify` (C2). Without it the highest-consequence silent failure in the chain has no guard at all.
3. Confirm free disk ≥ the size of `memory.db`, and know that a failed snapshot means the daemon refuses to start.
4. Take an independent backup of `~/.local/state/axi/memory.db` **before** the first restart on the new code. The in-process snapshot is the designed rollback; a copy made outside the process is the one that survives the process failing.
5. Note where the snapshot lands (`memory.db.pre-rebuild-<epoch>.db`, same directory) and keep it until the graph has been used and verified.
6. Decide on C3: wire `report_dangling_edges` into startup or a CLI, or untick 7.14.

## Design coherence

| Decision | Honoured? |
|---|---|
| Reachability probe is the ONLY authoritative VPN gate | Yes — no `connectivity_plus`, no `TRANSPORT_VPN` in the path |
| Revocation as an injected fail-closed callback | Yes, and hardened beyond design (no `None` default) — but `design.md:20` was never updated (W6) |
| PoP reuses the Ed25519 request scheme | Yes, and ordered before code redemption |
| Slice 3 as 3a/3b/3c, CASCADE left in place | **Superseded** by `design-schema.md`'s PR5–PR8; `design.md` never records this (W6) |
| Tombstones before rebuild (gate 7.12) | Yes — zero `DELETE FROM nodes/edges` remain in `axi/src/axi/*.py` |
| Tombstone indexes partial, diverging from mobile's DDL | Yes, deliberate, and guarded by three tests |

## Known-open, excluded by instruction

Tombstone purge/GC (unowned), `/api/graph/full` whole-table read, redundant uuid indexes from `migrate_nodes_edges_sync_columns`, tasks 2.7/2.8.

---

## Strict TDD sections

### TDD Compliance
| Check | Result | Details |
|---|---|---|
| TDD evidence reported | ✅ | `apply-progress.md` carries per-phase RED/GREEN narration plus five independent "Coordinator verification" sections (L978, 1195, 1442, 1816, 2190) |
| All tasks have tests | ⚠️ | 1 exception — 7.14's `report_dangling_edges` has tests but no production caller (C3) |
| RED confirmed (test files exist) | ✅ | every named test file exists; 1.15 and 1.16 record RED proven by temporarily reverting production code |
| GREEN confirmed (tests pass now) | ✅ | 471/471 axi, 35/35 mobile, re-executed this session |
| Triangulation adequate | ✅ | e.g. PoP has 4 cases (missing, wrong key, valid, code-not-burned); the VPN gate has 8 |
| Safety net for modified files | ✅ | each phase diffed its failure set with `comm` against its predecessor tip; empty both directions |

**TDD compliance**: 5/6 checks passed.

### Test Layer Distribution
| Layer | Tests | Files | Tools |
|---|---|---|---|
| Unit (axi) | ~430 | 12 | pytest |
| Integration (axi, HTTP/TestClient + real SQLCipher DB) | ~41 | 3 (`test_dashboard`, `test_pair_endpoint`, `test_graph_browser`) | pytest + fastapi TestClient |
| Unit (mobile) | 35 | 6 | flutter_test |
| E2E | 0 | 0 | not installed |
| **Total executed** | **506** | **20** | |

No test uses a tool absent from the environment. The absent layer is the one that matters here: nothing exercises a real device, a real tunnel, or the user's real database (see production gaps).

### Changed File Coverage
Coverage analysis skipped — no coverage tool configured for either stack (`pytest-cov` absent from the venv, no `--coverage` wiring in `mobile/`). Not a failure; not available.

### Assertion Quality
Audited every test file touched by this change. No tautologies, no assertions that never call production code, no ghost loops, no smoke-only tests. Empty-collection assertions all have a companion non-empty case (e.g. `test_store.py:856` asserts `updated_at > before` alongside the tombstone's presence; the tombstone-invisibility tests assert both the hidden read AND the row still present with `deleted_at` set).

Two assertions worth naming as strong rather than weak:
- `test_store_migration.py:637` asserts the tombstone index is **not** chosen for the live-row filter — "SEARCH, not SCAN" would have passed while hiding a full scan.
- `test_migration_backup.py:90` damages a **real** snapshot (truncate to a third) instead of mocking the verifier's return value.

**Assertion quality**: ✅ all assertions verify real behaviour. 0 CRITICAL, 0 WARNING.

### Quality Metrics
**Linter**: ➖ not run (no ruff/analyze gate configured in this change's CI path).
**Type checker**: ➖ not available for `axi` (no mypy config); `flutter analyze` not part of the verified command set.
