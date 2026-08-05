# Apply Progress: Relationships Robustness

## Status

- **Slice 1 — Characterization + parity harness: DONE.**
- **Slice 2 — person-identity (2a-i, 2a-ii, 2b): DONE.**
- **Slice 3 — relation-links (storage/write/derived reciprocity): DONE this
  run (domain + repository layer; UI wiring deferred, see below).**
- **Slice 5 — couple-partner-scoping (5a unnamed identity, 5b partner change,
  5c repository backfill): DONE this run (domain + repository layer; widget
  UI deferred, see below).**
- Slice 4 (reciprocity wired into `relationship_reminders.dart`), Slice 6
  (dates/deceased), Slice 7 (contact-clock kind parity): NOT started (out of
  scope this run, per explicit user instruction — untouched).

## Files changed this run (Slices 3 and 5)

- `mobile/lib/features/memory/domain/relation_links.dart` (NEW) — pure:
  `RelationLink` (append-only multi-edge `(kind, target person_id)` model),
  `linksBothWays()` (the single derive-at-read reciprocity accessor the design
  names — implemented this run per the user's explicit scope grant, even
  though tasks.md files it under Slice 4; NOT wired into
  `relationship_reminders.dart`'s reminder computation, which stays
  Slice 4's own task and untouched), `resolveRelationTarget()` (precision-first:
  exact one-match resolves, zero/ambiguous matches return an explicit
  "unlinked" status without dropping the free-text label).
  `mobile/test/features/memory/domain/relation_links_test.dart` (NEW) —
  11 tests, TDD RED→GREEN.
- `mobile/lib/features/domains/data/local_domain_repository.dart` (MODIFIED)
  — added `createPersonLink()` (append-only: always mints a new
  `kind:'person_link'` node, so a second recorded role never overwrites the
  first), `listPersonLinks()`, `linksBothWaysFor()`, `resolveRelationTargetFor()`
  (resolves against stored `person_identity` nodes).
  `mobile/test/features/domains/data/local_domain_repository_relation_links_test.dart`
  (NEW) — 6 tests, TDD RED→GREEN.
- `mobile/lib/features/memory/domain/couple_partner.dart` (NEW) — pure:
  `couplePartnerDisplayLabel()` + `kUnnamedPartnerPrompt` — the binding user
  answer says the partner's name has not been supplied, so this is the one
  place that rule is enforced: never invents a name, never blank.
  `mobile/test/features/memory/domain/couple_partner_test.dart` (NEW) —
  3 tests, TDD RED→GREEN.
- `mobile/lib/features/domains/data/local_domain_repository.dart` (MODIFIED
  further) — added `currentPartnerId()` (lazily mints ONE `unnamed: true`
  `kind:'person_identity'` node flagged `is_current_partner: true`, idempotent
  thereafter), `mintNewCurrentPartner()` (partner change: mints a new unnamed
  identity, moves the pointer, unsets the previous one's flag — old acts keep
  their old `partner_id`, nothing reattributed), `backfillCoupleActsToCurrentPartner()`
  (additive, idempotent batch: attaches the current partner's id to every
  `couple_act` fact entry that has none yet, preserving every other field —
  never touches an act that already carries a `partner_id`). `create()` now
  defaults a new `couple_act`'s `partner_id` to the current partner when the
  caller doesn't supply one (zero extra taps per spec), and never overrides
  an explicitly given one.
  `mobile/test/features/domains/data/local_domain_repository_couple_partner_test.dart`
  (NEW) — 10 tests, TDD RED→GREEN.

## Deferred this run (flagged, not silent — same precedent as Slice 2's banner)

- **Slice 3's UI wiring** (task 4's confirmation-UI half in
  `local_entry_config.dart`/`domain_entry_form.dart`): the storage/resolution
  layer is complete and tested; no widget yet shows the "unlinked" state to
  the user. tasks.md's own line-budget note already anticipated splitting
  this task.
- **Slice 4** (wiring `linksBothWays()` into `relationship_reminders.dart`'s
  reminder computation): explicitly out of scope this run per the user's
  instruction ("Do NOT touch slices 4, 6 or 7"). `relation_links.dart`'s
  `linksBothWays()` itself IS implemented (the user's scope description named
  it explicitly as part of "Slice 3" for this run), but nothing calls it from
  the reminder pipeline yet — that remains Slice 4's own task.
- **Slice 5's widget UI** (task 6/7's "unassigned" / "name your partner"
  prompt on the Relaciones screen, `local_domain_tab_test.dart`): the domain
  rule (`couplePartnerDisplayLabel`) and the repository-level backfill are
  built and tested; no screen calls them yet.
- Slices 6 and 7: untouched, per explicit user instruction.

## Verification performed (this run)

- `flutter analyze` (whole project): clean (0 issues) after every change,
  confirmed again at the end.
- Full `mobile` `flutter test`: **1632 → 1662 passing, zero regressions**
  (30 new tests: 11 + 6 + 3 + 10). The 54 `relationship_reminders_test.dart`
  tests and every other pre-existing suite are green and unmodified.
- No Python files touched this run (Slices 3/5 are phone-only capabilities);
  the Python parity suite from Slice 1 was not re-run since nothing on that
  side changed.

## Rollback (this run's additions)

- `kind:'person_link'` nodes are new and additive — revert the PR, old
  readers never see them, free-text `relation` labels remain exactly as
  recorded pre-slice.
- The current-partner identity is a new, additive `kind:'person_identity'`
  node; `backfillCoupleActsToCurrentPartner()` only ADDS a `partner_id` field
  to existing `couple_act` entries (every other field, and the entry itself,
  is preserved) — reverting the PR stops new code from reading/writing that
  field; the field's presence on old rows is harmless to code that predates
  it (mirrors Slice 2's "additive field, not a destructive rewrite" pattern).

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
