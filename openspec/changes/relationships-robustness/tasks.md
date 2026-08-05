# Tasks: Relationships Robustness

Ordered slices per `proposal.md`/`design.md`. Each slice ≤400 changed lines
(per-task line estimates below; totals include test code). TDD strict mode:
every behaviour-changing task lists its failing test as a separate,
preceding step. `flutter analyze` (whole project) is a mandatory step in
every slice that touches `mobile/`, not an assumption.

Test runners:
- Dart: `cd mobile && flutter test`
- Python: `PYTHONPATH=lifeos/src python3 -m pytest lifeos/tests/...` (no venv
  on this machine — engine suite runs in CI on the laptop, not here)

---

## Slice 1 — Characterization + parity harness (safety net, ships first)

**[x] STATUS: DONE.** See `apply-progress.md` for files/verification. All 5
tasks below complete; `parity/relationships/cases.json`,
`relationships_parity_test.dart`, `test_phone_parity.py`,
`person_identity_characterization_test.dart` all created and GREEN;
`flutter analyze` clean; full suites green (mobile 1605→1632, python 64→71).

Satisfies: Spec "Slice 1 — Characterization Tests"; Cross-Cutting
"Deterministic clock/number math (ADR-4)". No behaviour change — this slice
only locks current semantics as the migration baseline.

Sequential (this slice is a prerequisite for all later slices; no parallel
tasks inside it).

1. **[test]** Add `parity/relationships/cases.json` golden fixture: hand-author
   cases covering folding, `due_for_contact`/`contactsDue`, birthday/age math,
   at least one case reserved (empty/placeholder shape) for the future
   conflict-kind case landed in Slice 7.
   Est.: ~120 lines (JSON data, no production code).
   Rollback: delete the file; nothing else references it yet.
2. **[test]** Create `mobile/test/features/memory/domain/relationships_parity_test.dart`
   loading `cases.json` and asserting `contact_nudge.dart`/
   `relationship_reminders.dart` outputs match exactly. Expect RED initially
   only if the fixture exposes an existing Dart/Python mismatch — otherwise
   GREEN immediately since it characterizes current behaviour.
   Est.: ~90 lines.
   Breaks: none (additive test file; does not touch existing 54 tests in
   `relationship_reminders_test.dart`).
3. **[test]** Create `lifeos/tests/relationships/test_phone_parity.py` loading
   the same `cases.json`, asserting `people.py`'s `last_contact`/
   `due_for_contact` match the fixture's expected outputs.
   Est.: ~90 lines.
   Breaks: none (new test module).
4. **[test]** Add characterization tests locking today's folding
   (accent/case fold: "María"/"Maria" → same key on phone) and the
   `\bde\s+(.+)$` relation-target parse, in a new
   `mobile/test/features/memory/domain/person_identity_characterization_test.dart`.
   These MUST pass against current code unmodified — they are a lock, not a
   RED-then-GREEN pair.
   Est.: ~80 lines.
   Breaks: none.
5. Run `flutter analyze` (whole project) and the full `flutter test` suite;
   run the pytest module. Confirm all green, confirm the 54 existing
   `relationship_reminders_test.dart` tests are untouched.
   Est.: 0 lines (verification step only).

**Slice 1 total: ~380 lines.** Fits the 400-line budget with no split
needed.

---

## Slice 2 — Capability: person-identity (ULID + migration + rename)

**[x] STATUS: 2a-i, 2a-ii, 2b DONE this run.** See `apply-progress.md`.
`person_identity.dart` (fold/ULID/migration-grouping/rename/collision, pure,
18 tests), `local_domain_repository.dart`'s `migratePersonIdentities()` /
`renamePersonIdentity()` / `collidingPersonIds()` (10 tests), all TDD
RED→GREEN. **DEVIATION FLAGGED**: uses `kind:'person_identity'`, not
`kind:'person'` as design.md specifies — see apply-progress.md for why
(`kind:'person'` already used by the chat-memory hub/PersonDirectory system).
Needs reconciliation with design.md before Slice 3/5.

Satisfies: Spec Slice 2 (Stable person identity, non-destructive migration,
collision detection). Depends on Slice 1 (parity harness + characterization
lock must exist first, since migration groups by the exact folded-name rule
Slice 1 characterized).

Sequential internally (migration must exist before rename can be tested
against it); can run in parallel with Slice 6 (no shared files) once Slice 1
lands, per Dependency graph below.

1. **[test]** Write failing tests for `person_identity.dart` (new file): fold
   function (same characterization as Slice 1, now used to key ULIDs),
   ULID minting, migration grouping (exactly-today's-folding groups → one
   ULID per group).
   Est.: ~110 lines.
2. **[impl]** Implement `mobile/lib/features/memory/domain/person_identity.dart`:
   pure fold/resolve/migration-grouping functions, ULID minting.
   Est.: ~130 lines.
3. **[test]** Write failing tests for migration runner in
   `local_domain_repository_test.dart` (or new file): v2 records written
   alongside originals, originals untouched, idempotent re-run, loud
   "migration incomplete" state on malformed subset.
   Est.: ~90 lines.
4. **[impl]** Implement migration runner in `local_domain_repository.dart`:
   groups existing `person` entries, mints `kind:'person'` identity nodes,
   never deletes/rewrites originals.
   Est.: ~140 lines.
5. **[test]** Write failing tests for rename op: `person_id`, `knownSince`,
   links, history unchanged; only `canonical_name` + `folded_keys[]` updated.
   Est.: ~60 lines.
6. **[impl]** Implement rename op.
   Est.: ~70 lines.
7. **[test]** Write failing tests for collision detection: new/renamed
   person's folded name matches an existing different `person_id` →
   non-blocking indicator on both records; rename still completes.
   Est.: ~70 lines.
8. **[impl]** Implement collision detection (detection only, no merge/split
   per proposal decision (a)).
   Est.: ~60 lines.
9. Run `flutter analyze` (whole project). Confirm
   `relationship_reminders_test.dart` (54 tests) still green — identity
   layer is additive; if any break, note which and fix before merging (do
   not silently adjust the golden fixture to match).
   Est.: 0 lines.

**Slice 2 total: ~730 lines split across two sub-slices to respect budget:**
- **2a** (tasks 1–4, migration): ~470 lines — **exceeds 400, split further**:
  2a-i (fold + migration grouping, tasks 1–2): ~240 lines. 2a-ii (migration
  runner, tasks 3–4): ~230 lines.
- **2b** (tasks 5–8, rename + collision): ~260 lines — fits as-is.

Rollback: migration is additive (v2 `kind:'person'` nodes beside untouched
originals) — revert the PR, old code reads originals only, sees no v2 kind,
nothing lost. Rename/collision revert independently (no data deleted by
either).

---

## Slice 3 — Capability: relation-links (storage, write path, loud unresolved state)

**[x] STATUS: DONE this run (tasks 1–3, partial task 4).** See
`apply-progress.md`. `relation_links.dart` (model, `linksBothWays()` derived
reciprocity per the user's explicit scope grant this run, `resolveRelationTarget()`
precision-first resolution) + `local_domain_repository.dart`'s
`createPersonLink()`/`listPersonLinks()`/`linksBothWaysFor()`/
`resolveRelationTargetFor()`, all TDD RED→GREEN. **DEFERRED (like Slice 2's
migration banner)**: the `local_entry_config.dart`/`domain_entry_form.dart` UI
wiring (task 4's confirmation-UI half) — the domain/storage layer is complete
and tested, but no widget surfaces the "unlinked" flag yet. Not a task-list
item skipped silently: flagged here, same precedent as Slice 2.

Satisfies: Spec Slice 3. Depends on Slice 2 (needs `person_id` to target).

Sequential.

1. **[test]** Write failing tests for `relation_links.dart` (new file):
   `(kind, target person_id)` edge model, append-only (second role does not
   erase first).
   Est.: ~70 lines.
2. **[impl]** Implement link model + append-only storage in
   `relation_links.dart` and `local_domain_repository.dart`
   (`kind:'person_link'` nodes).
   Est.: ~130 lines.
3. **[test]** Write failing tests for resolution: exact-one-match resolves;
   zero-match keeps label + shows "unlinked"; ambiguous match keeps label +
   shows "unlinked" (never auto-selects).
   Est.: ~90 lines.
4. **[impl]** Implement resolution logic + "unlinked" flag surfacing in
   `local_entry_config.dart` (link field) and `domain_entry_form.dart`
   (confirmation UI for resolved target).
   Est.: ~130 lines.
5. Run `flutter analyze` (whole project) and full `flutter test`. This slice
   modifies `local_entry_config.dart` and `domain_entry_form.dart` directly —
   expect `local_entry_config_test.dart` and `local_domain_tab_test.dart` to
   need updates for the new link field; treat any failure there as a
   required fix, not a fixture edit.
   Est.: 0 lines (plus whatever fixes those suites need, budgeted inside
   task 4's estimate).

**Slice 3 total: ~420 lines — over budget by ~20; split task 4 into 4a
(entry-config field, ~70 lines) and 4b (form UI confirm, ~70 lines) as two
commits within the same slice, or trim task 3's test scope to keep the slice
at ~400.**

Rollback: `kind:'person_link'` nodes are new and additive; revert the PR,
old readers never see them, free-text labels remain as they were pre-slice.

---

## Slice 4 — Capability: relation-links (derived reciprocity read/display)

Satisfies: Spec Slice 4. Depends on Slice 3 (needs stored links to derive
from).

Sequential; can run in parallel with Slice 5 once Slice 3 lands (different
files: `relation_links.dart` read path vs `couple_act` fields).

1. **[test]** Write failing tests for `linksBothWays()` in
   `relation_links.dart`: reciprocal relation browsable from both people, no
   second stored edge; multi-edge case considers all linked people, not only
   the first.
   Est.: ~90 lines.
2. **[impl]** Implement `linksBothWays()` — the single derive-at-read
   accessor.
   Est.: ~90 lines.
3. **[test]** Write failing tests in `relationship_reminders_test.dart` (adds
   to the existing 54) for multi-edge consideration in
   nearest-birthday-in-circle / reminder context.
   Est.: ~50 lines.
4. **[impl]** Wire `linksBothWays()` into `relationship_reminders.dart`
   reminder computation.
   Est.: ~60 lines.
5. `flutter analyze` (whole project); full `flutter test`. Expect
   `relationship_reminders_test.dart`'s existing 54 tests to still pass
   unmodified — this slice adds cases, it must not require editing existing
   assertions (if it does, that is a signal the read path changed
   observable behaviour and needs a proposal-level review, not a quiet
   fixture patch).
   Est.: 0 lines.

**Slice 4 total: ~290 lines.** Fits.

Rollback: revert the PR; `linksBothWays()` and its call site are additive
reads over Slice 3's already-additive storage — no data path removed.

---

## Slice 5 — Capability: couple-partner-scoping

**[x] STATUS: 5a, 5b, and the repository half of 5c DONE this run.** See
`apply-progress.md`. `couple_partner.dart` (pure `couplePartnerDisplayLabel()`,
never invents a name) + `local_domain_repository.dart`'s `currentPartnerId()`
(lazy, idempotent unnamed-partner mint), `create()`'s new couple_act default
to the current partner, `mintNewCurrentPartner()` (partner change, old acts
keep old `partner_id`), `backfillCoupleActsToCurrentPartner()` (legacy batch,
additive field write, idempotent). All TDD RED→GREEN. **DEFERRED (like Slice
2's migration banner and Slice 3's confirm-UI)**: the `local_domain_tab_test.dart`
widget-visible "unassigned"/"name your partner" prompt (task 6/7's UI half) —
the domain rule (`couplePartnerDisplayLabel`) is built and tested, but no
screen calls it yet.

Satisfies: Spec Slice 5. Depends on Slice 2 (needs identity layer for the
unnamed-partner identity per design). Can run in parallel with Slice 4.

Sequential internally.

1. **[test]** Write failing tests for unnamed current-partner identity:
   mint one `kind:'person'` with `unnamed: true`, `is_current_partner`
   pointer; all existing/new `couple_act` attach to it by default.
   Est.: ~80 lines.
2. **[impl]** Implement unnamed-partner identity + `partner_id` field on
   `couple_act` in `local_entry_config.dart`.
   Est.: ~90 lines.
3. **[test]** Write failing tests: partner change scopes new acts to new
   partner, old acts keep old `partner_id`, nothing deleted/reattributed.
   Est.: ~60 lines.
4. **[impl]** Implement partner-change flow (new identity, pointer move).
   Est.: ~70 lines.
5. **[test]** Write failing tests for legacy-bucket display: pre-scoping
   acts show "unassigned" + "name your partner to link these" prompt; naming
   the partner for the first time triggers one deterministic backfill batch
   attaching ALL pre-scoping acts; backfill is non-destructive (originals
   preserved).
   Est.: ~90 lines.
6. **[impl]** Implement backfill runner + "unassigned" UI state in
   `local_domain_tab_test.dart`'s corresponding widget
   (Relaciones screen) and repository backfill method.
   Est.: ~120 lines.
7. `flutter analyze` (whole project); full `flutter test`. Expect
   `local_domain_tab_test.dart` to need new cases for the "unassigned" /
   backfill-prompt UI state — flag any existing assertion it breaks before
   merging.
   Est.: 0 lines.

**Slice 5 total: ~510 lines — over the 200-line proposal estimate and over
budget; split into:**
- **5a** (tasks 1–2, unnamed partner identity + field): ~170 lines.
- **5b** (tasks 3–4, partner change): ~130 lines.
- **5c** (tasks 5–7, legacy backfill + UI): ~210 lines.

Rollback: partner identity/backfill are additive fields + one batch write
naming existing acts' `partner_id`; revert the PR and acts remain exactly as
recorded pre-backfill (the "unassigned" bucket reappears, nothing is lost —
per the proposal's Rollback Plan, no destructive rewrite at any point).

---

## Slice 6 — Capability: relationship-dates-lifecycle

Satisfies: Spec Slice 6. Independent of Slices 3–5 (touches date/deceased
fields only); can run in parallel with Slices 2b–5 once Slice 1 lands, since
it doesn't depend on the identity layer for its own fields (though the
reminder suppression check does read the deceased flag off the same person
record Slice 2 introduces — sequence after Slice 2a to avoid a merge
conflict on `local_entry_config.dart`).

Sequential internally.

1. **[test]** Write failing tests for `--MM-DD` year-optional parsing in a
   new/extended date-utils test: no age computed or displayed when year is
   absent; full y/m/d date still supports `turning`/age.
   Est.: ~70 lines.
2. **[impl]** Implement year-optional birth date parser (`--MM-DD` ISO 8601
   no-year), update `birthdays.dart` age suppression logic.
   Est.: ~80 lines.
3. **[test]** Add the year-optional case to `parity/relationships/cases.json`
   (Slice 1's fixture) and assert both `birthdays.dart` and `people.py`
   agree it produces no age. This is the one case in this slice that must
   touch the shared golden — do it as its own commit inside the slice so a
   reviewer can see the fixture diff in isolation.
   Est.: ~30 lines (fixture + one assertion each side; Python side deferred
   to Slice 7's parity work if `people.py` isn't touched yet — otherwise
   note as a stub case to activate later).
4. **[impl]** Update `domain_entry_form.dart` date picker to accept
   day/month-only entry.
   Est.: ~70 lines.
5. **[test]** Write failing tests for deceased/inactive boolean: suppresses
   birthday, contact-cadence, and context reminders on every surface.
   Est.: ~70 lines.
6. **[impl]** Add `deceased` boolean field to `local_entry_config.dart`,
   check it at the top of every reminder pipeline entry point in
   `relationship_reminders.dart`, `birthdays.dart`, `contact_nudge.dart`.
   Est.: ~90 lines.
7. `flutter analyze` (whole project); full `flutter test`. This slice
   directly modifies `contact_nudge.dart`/`birthdays.dart` and
   `local_entry_config.dart` — expect
   `relationship_reminders_test.dart` (54 tests) and
   `local_entry_config_test.dart` to need new deceased/year-optional cases;
   flag anything that breaks an EXISTING assertion (not just the new ones
   added here) before merging.
   Est.: 0 lines.

**Slice 6 total: ~410 lines — split into:**
- **6a** (tasks 1–4, year-optional date): ~250 lines.
- **6b** (tasks 5–7, deceased flag): ~160 lines.

Rollback: both fields are additive/optional on existing entries; revert the
PR, old picker/reminder logic resumes exactly as before — no data migrated
destructively.

---

## Slice 7 — Cross-runtime: contact-clock `kind` parity (reverses proposal decision f)

**CROSS-RUNTIME SLICE — DO NOT SPLIT ACROSS PRs.** Per design.md this must
ship phone + laptop + parity case together, in ONE PR/slice, because the
`MAX(ts)`-resets-clock gap is shared by
`lifeos/src/lifeos/relationships/people.py` and
`mobile/lib/features/memory/domain/contact_nudge.dart` /
`relationship_reminders.dart`. Splitting it would ship one side out of
lockstep and silently widen the exact drift this change exists to close.

Satisfies: Spec Slice 7 (all four requirements — logging never blocked,
conflict excludes from clock, fallback to `created_at` when only conflicts
exist, untyped legacy interactions keep today's behaviour). Depends on
Slice 1 (parity harness must exist; the reserved placeholder case from
Slice 1 task 1 gets filled in here).

Sequential, single slice, both runtimes touched in the same set of commits:

1. **[test]** Extend `parity/relationships/cases.json` with the conflict-kind
   case: last warm interaction 40 days ago, cadence 30 days, conflict
   interaction 2 days ago → person surfaced as due, conflict not treated as
   last contact. Add the only-conflicts-exist case (falls back to
   `created_at`) and the untyped-legacy case (counts toward `last_contact`
   as today).
   Est.: ~60 lines (fixture data).
2. **[test]** Extend `mobile/test/features/memory/domain/relationships_parity_test.dart`
   (Slice 1) to assert the new cases — RED against current Dart code
   (conflict currently resets the clock).
   Est.: ~40 lines.
3. **[test]** Extend `lifeos/tests/relationships/test_phone_parity.py`
   (Slice 1) for the same cases — RED against current `people.py`.
   Est.: ~40 lines.
4. **[test]** Write failing Dart tests in `relationship_reminders_test.dart`
   for: logging a conflict interaction is always allowed (never
   refused/hidden); conflict-kind excluded from `lastContact`/`contactsDue`;
   untyped legacy interactions unaffected.
   Est.: ~70 lines.
5. **[test]** Write failing Python tests (new
   `lifeos/tests/relationships/test_people_conflict_clock.py`, alongside
   existing `test_relationships_people_graph.py`-style suite) for the same
   three rules against `people.py`.
   Est.: ~60 lines.
6. **[impl]** Add `kind` field to Dart `interaction` model in
   `local_entry_config.dart` (enum mirroring laptop `_VALID_KINDS`, default
   `conversation`); update `contact_nudge.dart`/`relationship_reminders.dart`
   to exclude `kind == conflict` from `lastContact`/`contactsDue`, with
   `created_at` fallback when only conflicts exist.
   Est.: ~90 lines.
7. **[impl]** Add `kind` handling to `people.py`'s `last_contact`/
   `due_for_contact`: same exclusion + fallback rule.
   Est.: ~70 lines.
8. Run BOTH: `flutter test` (Dart parity + reminders suites) and
   `PYTHONPATH=lifeos/src python3 -m pytest lifeos/tests/relationships/` —
   confirm all four new parity cases pass byte-identically on both sides
   before considering this slice done. `flutter analyze` (whole project).
   Est.: 0 lines.

**Slice 7 total: ~430 lines — over the 400-line review budget by ~30 lines,
and it CANNOT be split across PRs per the design constraint above. Flag
this explicitly for a review-budget decision before apply** (see Review
Workload Forecast below): either trim task 1's fixture verbosity (~20–30
lines) to land under 400, or get explicit sign-off to exceed the budget for
this one slice given the no-split constraint takes precedence.

Rollback: `kind` field is additive with a safe default (`conversation`,
today's behaviour) on both platforms; revert the PR on BOTH runtimes
together (never one side alone — a one-sided revert reintroduces the exact
drift this slice closes). Existing interactions without a `kind` keep
counting toward `last_contact` exactly as before, on both sides, whether or
not the revert happens.

---

## Dependency Graph

```
Slice 1 (harness)
   │
   ├─→ Slice 2a-i → Slice 2a-ii → Slice 2b ─┬─→ Slice 3 → Slice 4
   │                                          │
   │                                          └─→ Slice 5a → Slice 5b → Slice 5c
   │
   ├─→ Slice 6a → Slice 6b   (parallel-safe after Slice 2a lands; merge-order
   │                          only, not a logical dependency)
   │
   └─→ Slice 7  (parallel-safe with everything above by content, but per
                design MUST land as one atomic cross-runtime PR; sequence
                it whenever convenient, never split it internally)
```

Parallelizable once Slice 1 is merged: Slice 6 (dates/deceased) alongside
Slice 2 chain; Slice 7 (interaction kind) alongside everything, since it
touches different files (`contact_nudge.dart`, `relationship_reminders.dart`
clock rule, `people.py`) than Slices 2–5's identity/links/partner work —
though `relationship_reminders.dart` is shared with Slice 4 and Slice 6b, so
whichever of Slice 4/6b/7 lands second should rebase, not blind-merge.

Strictly sequential: 2a-i → 2a-ii → 2b → 3 → 4; 2b → 5a → 5b → 5c.

---

## Review Workload Forecast

- **Total slices: 7 conceptual, expanding to 11 review-sized PRs** after
  splitting Slices 2, 3, 5, 6 to respect the 400-line budget (2a-i, 2a-ii,
  2b, 3, 4, 5a, 5b, 5c, 6a, 6b, 7).
- **Chained PRs are recommended.** `chain_strategy` was flagged as not yet
  chosen in the session preflight — this breakdown assumes `auto-chain`
  (already the session's `delivery_strategy`) applies per-PR in the
  dependency order above; confirm before apply that auto-chain is
  acceptable for an 11-PR chain rather than requiring per-slice manual
  gates.
- **One decision needed before apply**: Slice 7 is ~430 lines and cannot be
  split (cross-runtime constraint takes precedence over the line budget).
  Either trim ~30 lines from its fixture task or get explicit approval to
  exceed the 400-line budget for that one slice. Flagging now rather than
  discovering it mid-chain.
- All other slices/sub-slices fit within 400 lines as split above.
- Highest-risk review point: Slice 7, both for its size exception and
  because a reviewer must confirm both runtimes changed together (the
  no-split rule is a correctness requirement, not just a review-size
  convenience).
