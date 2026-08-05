# Proposal: Relationships Robustness

## Intent

Two silent data-loss bugs shipped in this model already (032e9229, fc372371); the exploration ranks nine more of the same shape. Root cause is shared: the phone keys people by folded name and stores links as parsed free text, so errors vanish instead of failing. Goal: make person data on the phone trustworthy — wrong links become impossible or loud, never silent — while keeping entry cost near zero for one person typing on a phone.

## Decisions (each auditable)

| # | Question | Decision | Rationale / tradeoff accepted |
|---|----------|----------|-------------------------------|
| a | Stable identity + rename/merge | **IN**: ULID `person_id` (converges toward laptop model) + rename op. **Merge/split tooling OUT** | Identity collision is the top-ranked next silent bug. Rename removes the main duplicate source. Merge UI deferred: phone UI cost high, need unproven — revisit if Q2 below says collisions exist |
| b | Relations | **IN**: structured links `(kind, target person_id)`, multi-edge append (fixes overwrite gap #3). Free text stays as display label; a typed relation must resolve to exactly one person or the entry is visibly flagged "unlinked" — never a silent no-link. Reciprocity **derived** at read, never stored | Cost accepted: resolving a target is one extra confirmation tap vs. raw typing. Stored reciprocity would double writes and create update anomalies; derivation is deterministic code (ADR-4) |
| c | Couple acts partner ref | **IN**: optional `partner_id`, defaults to current partner (zero extra taps). Partner change = new acts scope to new partner; old acts keep old scope, never deleted | Without it, post-breakup data blends forever (gap #4). Backfill needs the user to name the partner once (open Q1) |
| d | Year-optional birth date | **IN** | Direct precision-over-reach fix: show the birthday, never a guessed age. Cheap |
| e | Deceased/inactive flag | **IN**: single boolean, no ceremony | A birthday reminder for a dead person is worse than silence. Tiny cost |
| f | Interaction `kind` | **OUT** (own future change) | The conflict-resets-clock gap is shared phone+laptop; a phone-only fix widens the documented hand-sync drift, and a `kind` field without behavior is inert entry burden. Must ship both sides in lockstep with a parity test |

## Scope

### In Scope
- Characterization + phone↔laptop parity tests for current identity/date math (safety net first)
- ULID person identity, lazy migration, rename
- Structured multi-edge relation links, loud unresolved-link state, derived reciprocity
- `couple_act` partner scoping + guided backfill
- Year-optional birth dates; deceased flag

### Out of Scope (why)
- Phone↔laptop transport/sync — user's standing decision
- Interaction `kind` / contact-clock semantics — lockstep cross-platform change, separate proposal
- Merge/split tooling — deferred until a real collision is confirmed
- Groups, households, multi-hop relations, anniversaries — reach without demonstrated need

## Capabilities

### New Capabilities
- `person-identity`: stable person IDs, name folding, rename, migration from name-keyed entries
- `relation-links`: structured multi-edge links, loud resolution failure, derived reciprocity
- `couple-partner-scoping`: partner reference on couple acts, partner-change behavior, backfill
- `relationship-dates-lifecycle`: year-optional birth dates, deceased/inactive flag

### Modified Capabilities
- None (no existing specs).

## Approach — ordered slices (auto-chain, ≤400 lines each)

| Slice | Content | Est. lines |
|-------|---------|-----------|
| 1 | Characterization tests: folding, `de`-parsing, re-entry dedupe; parity fixtures vs `people.py` | ~250 (tests) |
| 2 | `person_id` + migration + rename | ~350 |
| 3 | Structured links: storage, write path, loud unresolved state | ~350 |
| 4 | Derived reciprocity read/display; multi-edge in reminders | ~250 |
| 5 | `couple_act` partner scoping + backfill flow | ~200 |
| 6 | Year-optional birth date + deceased flag | ~250 |

## Migration (real data on the phone — non-destructive)

- One-time deterministic upgrade: group existing entries by folded name (exactly today's semantics — nothing merges or splits differently), mint one ULID per group, write v2 records. Originals untouched.
- Relation strings become structured links only when the target resolves to exactly one person; otherwise the string remains a label and the person shows an explicit "unlinked" state. No guessing.
- Couple acts stay in a visible legacy bucket until the user names the partner once, then backfill.

## Affected Areas

| Area | Impact |
|------|--------|
| `mobile/lib/features/domains/domain/local_entry_config.dart` | Modified (person/couple_act fields) |
| `mobile/lib/features/.../relationship_reminders.dart` | Modified (ID keying, links) |
| `mobile/lib/features/.../birthdays.dart`, `contact_nudge.dart` | Modified (year-optional, deceased) + parity tests |
| `mobile/lib/features/domains/domain/domain_entry_form.dart` | Modified (date picker, link resolution) |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Migration mis-groups existing entries | Low | Slice 1 characterization tests lock current grouping before any change; originals preserved |
| birthdays/contact_nudge drift from `people.py` | Med | Parity fixtures in slice 1; laptop untouched otherwise |
| Structured entry feels like a chore | Med | Free text stays; structure is resolution + confirmation, not forms |

## Rollback Plan

Migration is additive (v2 records beside originals); rollback per slice = revert the PR, app falls back to reading original records. No destructive rewrite at any point.

## Dependencies

- User answers to open questions (below) before slices 2 and 5 finalize.

## Success Criteria

- [ ] Two same-named people can exist as distinct entries; re-entering an existing person still dedupes
- [ ] A rename preserves `knownSince`, links, and history
- [ ] A relation that fails to resolve is visibly flagged, never silently dropped
- [ ] Reciprocal relations are browsable from both people without double storage
- [ ] Couple acts filter by partner; old-partner acts survive a partner change
- [ ] A year-less birthday fires with no age shown; a deceased person fires nothing
- [ ] Parity fixtures pass identically against `birthdays.dart`/`contact_nudge.dart` logic and `people.py`

## Proposal question round

Need HIS answer:
1. Name of the current partner for the couple-act backfill — and should ALL existing acts attach to them?
2. Do any two different people with the same name exist in current data? (Yes → merge/split tooling moves in-scope.)
3. Does he actually want to log conflicts/arguments? (Drives priority of the deferred `kind` change.)

Decided by the proposal (correct if wrong): reciprocity derived not stored; interaction `kind` deferred to a lockstep cross-platform change; merge tooling deferred; migration lazy-additive rather than eager rewrite.
