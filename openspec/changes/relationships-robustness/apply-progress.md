# Apply Progress: Relationships Robustness

Scope for this run (explicit user instruction): **Slice 1** (parity/characterization
harness) and **Slice 2** (2a-i, 2a-ii, 2b — ULID person identity + additive
migration + rename + collision detection) only. Slices 3-7 are **NOT started**
in this run.

## Status

- **Slice 1 — Characterization + parity harness: DONE.**
- **Slice 2 — person-identity (2a-i, 2a-ii, 2b): DONE.**
- Slices 3, 4, 5, 6, 7: not started (out of scope this run, untouched).

## Files changed

- `parity/relationships/cases.json` (NEW) — golden fixture. 7 active cases
  (never-contacted-due, interaction-resets-clock, cadence-not-elapsed,
  most-recent-interaction-wins, no-cadence-never-due, birthday-within-window,
  birthday-outside-window) + 1 `reserved: true` placeholder for Slice 7's
  conflict-kind case (both parity suites skip `reserved` cases).
- `mobile/test/features/memory/domain/relationships_parity_test.dart` (NEW) —
  loads the golden, calls `contactsDue()`/`upcomingBirthdays()` directly.
  7 tests, GREEN (characterization lock, not a RED→GREEN pair).
- `lifeos/tests/relationships/test_phone_parity.py` (NEW) — loads the same
  golden, calls `people.due_for_contact()`/`people.upcoming_birthdays()`.
  7 tests, GREEN. Overwrites `created_at` via direct SQL after
  `people.create()` — SQLite's `datetime('now')` column default runs inside
  the SQLite engine and freezegun cannot reach it.
- `mobile/test/features/memory/domain/person_identity_characterization_test.dart`
  (NEW) — locks today's accent/case fold and the `\bde\s+(.+)$` relation-target
  parse through the PUBLIC `trackedPeopleFrom`/`relationshipReminders` surface
  (the underlying `_key`/`_relationTarget` are private). 6 tests, GREEN.
- `mobile/lib/features/memory/domain/person_identity.dart` (NEW) — pure:
  `foldPersonName()` (single source of truth for the fold rule), `mintUlid()`
  (Crockford base32, injected clock + `RandomBytesSource`), `PersonIdentity`,
  `NameOccurrence`, `groupForMigration()`, `renamed()`,
  `foldedKeyCollidesWithOther()`.
  `mobile/test/features/memory/domain/person_identity_test.dart` (NEW) —
  18 tests, TDD RED→GREEN.
- `mobile/lib/features/memory/domain/relationship_reminders.dart` (MODIFIED,
  no behavior change) — `_key()` now delegates to `foldPersonName()`. All 54
  existing tests in `relationship_reminders_test.dart` pass unmodified.
- `mobile/lib/features/domains/data/local_domain_repository.dart` (MODIFIED)
  — added `migratePersonIdentities()` (additive + idempotent: groups existing
  `relationships`/`person` fact entries by fold, mints
  `kind:'person_identity'` nodes, NEVER rewrites/deletes originals; malformed
  entries are named in `PersonMigrationResult.incompleteEntryUuids`, never
  silently dropped), `renamePersonIdentity()` (person_id unchanged, folded key
  appended not replaced), `collidingPersonIds()` (detection only — no
  merge/split, per the proposal's binding answer).
  `mobile/test/features/domains/data/local_domain_repository_identity_test.dart`
  (NEW) — 10 tests, TDD RED→GREEN.

## Deviation from design.md — flagged explicitly, not silent

`design.md`'s "Decision: Identity and links live outside the entry registry"
specifies `kind:'person'` for the new identity node. **That kind is already in
use** by the pre-existing chat-memory "known person" node:
`memory_writer.dart`'s hub node (`role:'user'`), `person_directory.dart`'s
`PersonDirectory.fromNodes`, `chat_context_builder.dart`,
`daily_digest_service.dart`, `mi_vida_notifier.dart`, and the graph browser's
"Personas" bucket — none of which the design or spec mentioned or accounted
for. Reusing `kind:'person'` would have silently injected non-conforming rows
(no `data.relation`, no `data.role`) into every one of those readers'
`listNodesByKind('person')` calls — exactly the kind of silent corruption the
non-negotiable constraints in this task forbid.

**Resolution taken**: used `kind:'person_identity'` instead of `kind:'person'`
for the new identity nodes. This needs to be reconciled with `design.md`
before Slice 3 (`kind:'person_link'` — should be independently checked for a
similar collision) and Slice 5 (the unnamed-partner identity also targets this
same kind).

## Verification performed

- `flutter analyze` (whole project): clean after every change (0 issues).
- Full `mobile` `flutter test`: **1605 → 1632 passing**, zero regressions.
  The 54 tests in `relationship_reminders_test.dart`,
  `local_entry_config_test.dart`, and `local_domain_tab_test.dart` are all
  green and unmodified.
- Full Python relationship suite (`test_relationships*.py` +
  `tests/relationships/`): **64 → 71 passing**, zero regressions.

## Not done / deferred (in scope, not a failure)

- No UI wiring for a "migration incomplete" banner. `PersonMigrationResult`
  surfaces `incompleteEntryUuids`/`isComplete` at the repository layer only —
  tasks.md's Slice 2 task list has no UI task for this (UI wiring first
  appears in Slices 3/5's lists).
- Slices 3-7 untouched, per explicit user scope instruction. Nothing done
  this run makes Slice 7's approved `size:exception` (~430 lines, must ship
  as one atomic cross-runtime PR) harder to keep atomic.
- Environment note (not a code change): this machine's scratchpad venv had
  neither `ulid-py` nor `sqlcipher3-wheels` preinstalled; both were installed
  via network pip to run the Python suite, matching the exact versions
  already pinned in `lifeos/pyproject.toml` (`ulid-py>=1.1`,
  `sqlcipher3-wheels>=0.5`). A fresh venv in a future session will need the
  same install repeated unless the venv is persisted.
