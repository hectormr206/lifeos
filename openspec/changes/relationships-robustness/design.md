# Design: Relationships Robustness

> **CORRECTION (applied during slice 2).** This document originally specified
> `kind:'person'` for the new identity nodes. That kind was ALREADY TAKEN: it is
> the pre-existing chat-memory "known person" node, read by `memory_writer.dart`
> (the user hub), `person_directory.dart`, `chat_context_builder.dart`,
> `daily_digest_service.dart`, `mi_vida_notifier.dart` and the graph browser's
> "Personas" bucket. Writing identity records under it would have injected rows
> none of those six readers understand — silently, which is the exact failure
> class this whole change exists to remove. The implementation used
> `kind:'person_identity'` and stopped to flag it rather than following the
> design off a cliff. The design was wrong; the code is right. Slices 3
> (`person_link`) and 5 (unnamed partner) build on `person_identity`.


## Technical Approach

Introduce a ULID person identity layer and structured links as **new graph-node kinds** beside the untouched `kind:'fact'` entries; keying moves from folded name to `person_id` at read time. Cross-platform behavior (contact clock, birthday math) is locked by a **shared golden fixture** both platforms run. Per binding user answers: interaction `kind` moves IN scope as a lockstep phone+laptop slice (reverses proposal decision f); the current partner exists as an **unnamed identity**; same-name collision handling is a detection guard only.

## Architecture Decisions

### Decision: Identity and links live outside the entry registry (new node kinds)

**Choice**: `kind:'person_identity'` nodes (identity: `person_id` ULID, `canonical_name`, `folded_keys[]`, `unnamed`, `deceased`) and `kind:'person_link'` nodes (`from_person_id`, `link_kind`, `to_person_id`, `label`, append-only) in `LocalGraphStore`. Small dedicated read/write methods in `LocalDomainRepository`.
**Alternatives considered**: (a) fact nodes with new `data.type`s in the registry — rejected: they would surface in the legacy entry list, gain edit/delete forms the user could mangle, and pollute a rolled-back app's list (old code shows unknown-typed facts). (b) Graph edges — rejected: a person is many fact nodes; edges need a node anchor that doesn't exist pre-identity.
**Rationale**: the registry's contract is "user-authored entry type with a generated form". Identity/links are derived system records. Cost accepted: two node kinds break the "pure data addition" virtue once; new user-facing FIELDS (`kind`, `partner_id`, deceased, year-optional date) still enter via the registry with zero widget code. Rollback becomes trivial: old code lists only `kind:'fact'` and never sees v2 records.

### Decision: Migration — lazy-additive, idempotent, fold-keyed

**Choice**: one-time runner in the repository: group existing `person` entries by today's exact `_key()` folding (characterization-locked in slice 1), mint one ULID identity per group with that folded key. Skip folded keys that already have an identity → idempotent, and roll-forward after rollback reuses the persisted IDs. Post-migration creates resolve name→identity at write time; unresolved names mint a new identity.
**Read resolution during overlap**: field values still come from original `fact` entries with today's per-field newest-wins merge; only the GROUPING key changes from folded name to `person_id` (via `folded_keys`). Rename = set `canonical_name` + append the new folded key, so pre- and post-rename entries resolve to one person. Revert = old code reads originals only; nothing lost.
**Alternatives**: eager rewrite of entries with embedded IDs — rejected (destructive, per-slice rollback impossible).

### Decision: Folding rule — phone rule wins; laptop gets a detection guard only

**Choice**: accent+case-insensitive fold (phone `_key()`) is the canonical resolution rule. Laptop `find_by_name` gains fold-aware lookup for NEW resolutions; existing laptop rows that would collide under folding ("María"/"Maria") are **flagged loudly, never merged** (user answer 2: detection only).
**Rationale**: phone typing drops accents routinely — accent-sensitive matching is a duplicate generator, the top-ranked silent bug. Reversing (splitting phone people by accent) would silently duplicate existing merged people.
**Escape hatch**: creating a person whose folded key already exists prompts "same as X?"; an explicit "no" mints a distinct ULID sharing the key, after which NAME-based resolution of that key is ambiguous → loud "unlinked", never a guess.

### Decision: Conflict does not reset the contact clock — lockstep + golden

**Choice**: `interaction` gains `kind` (enum mirroring laptop `_VALID_KINDS`, default `conversation`). Rule on BOTH sides: `kind == 'conflict'` never updates `lastContact`; everything else does. Phone: `trackedPeopleFrom`; laptop: `people.py` last-contact query. Shipped in ONE slice with the parity case, never split.
**Parity mechanism**: hand-authored golden fixture `parity/relationships/cases.json` at repo root (inputs: people, interactions with kinds, `now`; expected: due list, birthdays, ages, clock results). `mobile/test/.../relationships_parity_test.dart` and `lifeos/tests/relationships/test_phone_parity.py` load the SAME file and assert identical outputs. A behavior change on either side without a fixture update fails that side's CI — drift is loud (silent-failure rule).
**Alternatives**: code generation Py→Dart (toolchain weight), runtime embedding (transport-adjacent, out of scope). Rejected.

### Decision: Unnamed current partner; reciprocity derived at read (confirmed)

**Choice**: mint one identity with `unnamed: true` as the current partner; a single `kind:'person_identity'` config pointer (`is_current_partner`) selects it. ALL existing and new `couple_act`s attach to that ULID now; naming the partner later is a RENAME (set `canonical_name`), zero re-attribution. Partner change mints a new identity and moves the pointer; old acts keep the old ULID. Nudge/birthday readers skip `unnamed` identities.
**Reciprocity**: confirmed derived. One pure function `linksBothWays()` in new `relation_links.dart` is the ONLY accessor UI uses; it indexes both endpoints of stored `person_link` nodes at every read and shows the stored phrase from either end — no inverse-kind vocabulary invented, nothing stored to go stale.

## Data Flow

    person/interaction fact entries ──┐
    kind:'person_identity' identities ─────────┼→ resolve(fold→person_id) → per-field merge → TrackedPerson(id-keyed)
    kind:'person_link' nodes ─────────┘→ linksBothWays() → browsable both ways
    golden cases.json → Dart parity test ─┐
                      → pytest parity ────┴→ identical expected outputs

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `parity/relationships/cases.json` | Create | Golden fixture (slice 1) |
| `mobile/test/features/memory/domain/relationships_parity_test.dart` | Create | Runs golden |
| `lifeos/tests/relationships/test_phone_parity.py` | Create | Runs same golden |
| `mobile/lib/features/memory/domain/person_identity.dart` | Create | Fold, ULID resolve, migration grouping (pure) |
| `mobile/lib/features/memory/domain/relation_links.dart` | Create | Link model + `linksBothWays()` |
| `mobile/lib/features/domains/data/local_domain_repository.dart` | Modify | Identity/link IO, migration runner |
| `mobile/lib/features/domains/domain/local_entry_config.dart` | Modify | `kind`, `partner_id`, deceased, year-optional date |
| `mobile/lib/features/domains/domain/domain_entry_form.dart` | Modify | Year-optional picker, link-resolution confirm |
| `mobile/lib/features/memory/domain/relationship_reminders.dart` | Modify | ID keying, conflict-clock rule, deceased skip |
| `mobile/lib/features/memory/domain/{birthdays,contact_nudge}.dart` | Modify | Year-optional, deceased |
| `lifeos/src/lifeos/relationships/people.py` | Modify | Conflict-clock rule, fold-collision detection |

Year-optional birth date wire format: `birth_date: "--MM-DD"` (ISO 8601 no-year); `turning`/age suppressed when year absent — both parsers updated, golden case included.

## Testing Strategy

| Layer | What to Test | Approach |
|-------|-------------|----------|
| Unit (RED first) | Folding, migration grouping, rename, link resolution, clock-kind rule, `--MM-DD` | Characterization in slice 1 locks CURRENT behavior before any change |
| Parity | birthdays/contact_nudge vs people.py | Shared golden, both CIs |
| Widget | Unlinked flag visible, unnamed-partner state | Existing golden-test harness |

## Threat Matrix

N/A — no routing, shell, subprocess, VCS/PR automation, executable-file classification, or process-integration boundary.

## Migration / Rollout

Slices (auto-chain, each ≤400 authored lines): 1 characterization+golden harness → 2 identity+migration+rename → 3 links+loud unlinked → 4 reciprocity read+reminders → 5 unnamed partner+couple_act scoping → 6 year-optional date+deceased → 7 interaction `kind`+clock rule, phone+laptop+parity case in one PR. Rollback per slice = revert PR; v2 kinds invisible to old readers.

## Open Questions

- [ ] None blocking. Laptop fold-collision flag surfacing (log vs dashboard) decided at task level.
