# Exploration — relationships-robustness

Inventory of the person / family / couple data model. **No solution proposed here**;
this phase only records what exists, what is broken and what is missing.

Trigger: two user questions uncovered two real defects in two minutes, and both were
**silent** — nothing failed and nothing warned. That is the class of gap hunted below.

## Current state: three models that do not interoperate

| # | Model | Where |
|---|-------|-------|
| 1 | Phone LOCAL entries — `person`, `interaction`, `couple_act` | `mobile/lib/features/domains/domain/local_entry_config.dart:339-408` |
| 2 | Phone REST form for the laptop's interactions endpoint | `mobile/lib/features/domains/domain/domain_form_spec.dart:162-182` |
| 3 | Laptop engine — ULID `people`, `person_links`, `interactions` | `lifeos/src/lifeos/relationships/{people,store,ingestion}.py` |

`relationship_reminders.dart` bridges only model 1. `birthdays.dart` / `contact_nudge.dart`
are a hand-maintained Dart port of `people.py` with **no cross-parity test**, so the two
sides can drift silently.

## Already fixed (the shape being hunted)

- `032e9229` — a surname broke the family link: `"Juan Pérez García"` + `"hija de Juan"`
  silently never linked (exact string match).
- `fc372371` — a person told in pieces lost data: recording the birthday first and the
  relation later erased the birthday (newest record won wholesale).

## Findings

### Identity
Name is the ONLY key on the phone, accent- and case-folded
(`relationship_reminders.dart:232-245`). Two different people with the same folded name
collapse into one — through the very same code path that intentionally dedupes a
re-entered person, so nothing can tell the two cases apart. No stable ID, no rename
operation: fixing a typo orphans a duplicate and loses `knownSince` and family links.

**Divergence, verified:** the laptop indexes `LOWER(name)` (`store.py:105-110`) — case
insensitive but accent SENSITIVE. `"María"` and `"Maria"` are two people on the laptop
and one on the phone.

### Relationship modelling
`relation` is a single free-text field doing two jobs — the human label AND the family
link — parsed only by `\bde\s+(.+)$` (`relationship_reminders.dart:226-229`). It cannot
express: a second role for the same person (a later edit overwrites the first), reciprocity
(linking Sofía to Juan never makes Juan her father anywhere), multi-hop relations, or
groups/households. The laptop's `person_links(from_id, to_id, kind)` supports reciprocity
and several concurrent edges; the phone loses that expressiveness entirely.

### Couple / partner
`couple_act` has **no person or partner field at all** (`local_entry_config.dart:385-407`),
and "ella" is hardcoded feminine singular in the copy. The observation is unconnected to any
recorded `person`. With no partner scoping, acts accumulate into one bucket forever, so after
a change of partner the old and new relationships blend into a single observation.

### Dates and time
The picker always demands a full year (`domain_entry_form.dart:135-147`); a day/month-only
birth date cannot be recorded. A guessed year then feeds `turning` and is shown as a
confident age — the exact failure `birthdays.dart:6-7` says it avoids. No deceased/inactive
marker, so a dead person's birthday keeps firing. No anniversary or recurring date beyond
birthdays.

### Contact and interactions
The phone's `interaction` carries only a person name and a timestamp — no kind, direction or
channel. Both phone (`relationship_reminders.dart:107-114`) and laptop (`people.py:351-364`)
take `MAX(ts)` regardless of kind, so **logging an argument resets the "reach out" clock
exactly as a warm conversation would**. Shared gap, not phone-only.

### Silent-failure inventory, ranked

1. Two different people with the same folded name merge into one — untested.
2. A rename or typo fix orphans a duplicate person.
3. A later, different role overwrites the previous `relation` string.
4. `couple_act` has no partner scoping; post-breakup data blends in.
5. A conflict interaction resets the contact clock on both platforms.
6. A year-less birth date is forced into a guessed year and shown as a confident age.
7. No deceased/inactive marker.
8. The laptop-form `person_id` is unvalidated free text.
9. Reciprocity is never surfaced as a browsable fact.

## Open questions for the proposal

1. A stable person ID plus merge/rename on the phone.
2. Structured multi-edge relations vs. better-parsed free text.
3. Whether `couple_act` gains a partner reference and partner-change handling.
4. A year-optional birth-date mode.
5. Whether a deceased/inactive flag is in scope.
6. Whether interaction `kind` reaches the phone's local entry.

**Out of scope**, by the user's standing decision: phone↔laptop sharing transport.

## Risks

- The identity collision is the most likely NEXT silent bug of the same shape as the two
  already fixed, and has no test coverage today.
- Anything touching `relation`'s structure ripples into `birthdays.dart` and
  `contact_nudge.dart`, which are hand-synced with `people.py`; unmirrored changes widen the
  drift instead of closing it.
