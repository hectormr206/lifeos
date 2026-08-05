# Spec: Relationships Robustness

Full specs for four NEW capabilities plus one REVERSED-into-scope capability
(interaction kind / contact-clock parity — proposal decision (f) is reversed
by the user's binding answer). No existing specs exist for this domain, so
every section below is a full spec, not a delta. Organized by the proposal's
ordered slices so each stays inside the review budget.

## Cross-Cutting Invariants (apply to every capability below)

### Requirement: Precision over reach

The system MUST prefer no link/no value over a guessed one everywhere person
data is inferred (relation targets, age, partner attribution, identity match).

#### Scenario: Ambiguous relation target
- GIVEN a relation string names a person that matches more than one existing
  `person_id`
- WHEN the link is resolved
- THEN the system records no target and visibly flags the entry "unlinked"

### Requirement: Silence is the correct output, stated as such

Where no reliable signal exists, the system MUST show nothing rather than a
manufactured finding, and this MUST be indistinguishable from "not yet
computed" only in tests, never in the user-facing surface.

#### Scenario: No couple-act mismatch evidence
- GIVEN fewer than the evidence threshold of couple acts recorded
- WHEN the Relaciones screen renders
- THEN no love-language observation is shown, and no placeholder implies one is pending

### Requirement: Never a countdown, always a reason

Any nudge surfaced to the user MUST lead with a concrete reason (a fact, a
date, a name), and MUST NOT lead with an elapsed-day count as the primary text.

#### Scenario: Contact nudge copy
- GIVEN a person is due for contact with no nearby birthday context
- WHEN the nudge message is rendered
- THEN the message reads "Hace tiempo que no hablas con {name}" and does not print the day count as the headline

### Requirement: Deterministic clock/number math (ADR-4)

All date/day-count/age arithmetic (contact cadence, birthday proximity,
turning-age, days-since) MUST be computed by deterministic code with an
injected clock, and MUST NOT be produced or approximated by model inference.

#### Scenario: Days-since computed by code
- GIVEN a fixed `now` and a fixed `last_contact`
- WHEN days-since is computed
- THEN the result is reproducible byte-for-byte across repeated calls with the same inputs, with no model call in the path

---

## Slice 1 — Characterization Tests (safety net first)

### Requirement: Current folding/parsing/dedupe behavior is locked before any change

The system's test suite MUST characterize, byte-for-byte, the CURRENT
behavior of: accent/case name folding, the `\bde\s+(.+)$` relation-target
parse, and the per-field re-entry dedupe merge — before any slice 2+ change
lands.

#### Scenario: Folding characterization
- GIVEN the strings "María" and "Maria" as recorded on the phone today
- WHEN the existing fold function runs
- THEN the test asserts they fold to the same key (today's behavior, to be revisited by slice 2's collision guard)

#### Scenario: Cross-platform parity fixture exists
- GIVEN a shared fixture of (person, interactions, cadence, now) cases
- WHEN both `people.py` and `contact_nudge.dart`/`relationship_reminders.dart` compute due-for-contact
- THEN both outputs match exactly, and the fixture file is the single source both suites read

---

## Slice 2 — Capability: person-identity

### Requirement: Stable person identity

The system MUST assign every person a stable ULID `person_id` that survives
renames and never changes for that person's lifetime.

#### Scenario: Rename preserves identity
- GIVEN a person exists with a typo in their name
- WHEN the user renames them
- THEN `person_id`, `knownSince`, links, and history are unchanged; only the display name updates

### Requirement: Non-destructive migration from name-keyed entries

The system MUST migrate existing name-keyed local entries to `person_id`-keyed
v2 records by grouping exactly by today's folded-name semantics, minting one
ULID per group, and MUST leave original records untouched.

#### Scenario: Migration preserves originals
- GIVEN existing `person`/`interaction`/`couple_act` entries recorded before migration
- WHEN the one-time migration runs
- THEN one `person_id` is minted per folded-name group, v2 records are written alongside originals, and no original record is deleted or rewritten

#### Scenario: Migration failure is loud
- GIVEN the migration cannot complete for a subset of entries (e.g., malformed data)
- WHEN migration runs
- THEN the app shows an explicit "migration incomplete" state naming the affected entries, never a silent partial migration presented as complete

### Requirement: Same-folded-name collisions are visible, never silently merged or silently invisible

The system MUST detect when a new or renamed person's folded name matches an
existing, DIFFERENT `person_id`, and MUST surface a non-blocking "same name as
an existing person" indicator on both records. Merge/split resolution tooling
is explicitly OUT of scope; this requirement covers detection only.

#### Scenario: New person collides with existing person
- GIVEN a person "Juan Pérez" already exists
- WHEN the user creates a new person "juan perez" (same fold, different `person_id`)
- THEN both persist as distinct people AND each shows a "same name detected" indicator

#### Scenario: Rename produces a collision
- GIVEN a rename would make one person's folded name match another existing person's
- WHEN the rename is saved
- THEN the rename completes (never blocked) AND the indicator appears on both records

#### Scenario: No collisions in today's data (regression guard)
- GIVEN the migration runs against the user's current data, where he confirms no two distinct people share a folded name today
- WHEN migration completes
- THEN a characterization test asserts zero collision indicators are raised

---

## Slice 3 — Capability: relation-links (storage, write path, loud unresolved state)

### Requirement: Structured multi-edge relation links

The system MUST store relation links as `(kind, target person_id)` pairs
appended as new edges, so a person can hold more than one role
simultaneously and a later edit never silently overwrites an earlier one.

#### Scenario: Second role does not erase the first
- GIVEN a person is linked as "hija de Juan"
- WHEN the user later also records them as "prima de Ana"
- THEN both links persist as separate edges; neither overwrites the other

### Requirement: A link that cannot resolve is visibly flagged, never silently dropped

The system MUST attempt to resolve a typed relation phrase to exactly one
`person_id`. When it resolves to zero or more than one candidate, the system
MUST keep the original free-text label AND show an explicit "unlinked" state.

#### Scenario: No target found
- GIVEN a relation phrase names nobody in the current people list
- WHEN the entry is saved
- THEN the free-text label is kept, and the person's detail view shows "unlinked" — not silence

#### Scenario: Ambiguous target found
- GIVEN a relation phrase matches two distinct `person_id`s
- WHEN the entry is saved
- THEN no target is auto-selected, the label is kept, and "unlinked" is shown

---

## Slice 4 — Capability: relation-links (derived reciprocity read/display)

### Requirement: Reciprocity is derived at read time, never stored

The system MUST compute the reverse relation (e.g., linking Sofía to Juan as
"hija de Juan" makes Juan browsable as "padre de Sofía") by deriving it from
the single stored edge at read time. It MUST NOT store a second, separate
reciprocal edge.

#### Scenario: Reciprocal relation is browsable
- GIVEN Sofía is linked to Juan with kind "hija"
- WHEN Juan's detail view is opened
- THEN Sofía appears in Juan's relations with the derived inverse kind, with no separate stored write for it

#### Scenario: Multi-edge appears in reminders
- GIVEN a person has two or more relation links
- WHEN reminders/context (e.g., nearest-birthday-in-circle) are computed
- THEN all linked people are considered, not only the first-recorded one

---

## Slice 5 — Capability: couple-partner-scoping

### Requirement: Couple acts carry an optional partner reference, defaulting to the current partner

The system MUST let a `couple_act` reference a `partner_id`, defaulting to the
current partner with zero extra taps once one is set.

#### Scenario: New act defaults to current partner
- GIVEN a current partner is set
- WHEN the user records a new couple act without specifying a partner
- THEN it is scoped to the current partner automatically

### Requirement: Partner change scopes future acts without altering the past

The system MUST scope newly recorded acts to a new partner after a partner
change, and MUST NOT delete, reattribute, or reinterpret acts recorded under a
previous partner.

#### Scenario: Partner change preserves history
- GIVEN acts exist under partner A
- WHEN the user changes the current partner to B
- THEN new acts scope to B, and A's acts remain visible under A, unchanged

### Requirement: Legacy couple acts stay in a visible, explicitly-unassigned bucket until the user names a partner

Because the partner's name has not yet been supplied, the system MUST NOT
guess, invent, or silently default a partner name for the backfill. Existing
pre-scoping `couple_act` entries MUST remain visible and intact, labeled as
awaiting partner assignment, until the user names the current partner once.

#### Scenario: No partner named yet
- GIVEN pre-scoping couple acts exist and no partner has been named
- WHEN the user opens the Relaciones screen
- THEN the app shows an explicit "name your partner to link these" prompt, and the legacy acts remain visible under an "unassigned" label — never hidden, never attributed to a guessed name

#### Scenario: Partner named for the first time triggers backfill
- GIVEN the user supplies the current partner's name for the first time
- WHEN the one-time backfill runs
- THEN ALL pre-scoping `couple_act` entries are attributed to that partner's `person_id` in one deterministic batch, and the "unassigned" label disappears for those entries

#### Scenario: Backfill is non-destructive
- GIVEN the backfill has run
- WHEN the user inspects the acts
- THEN the original entries are preserved (per the Rollback Plan) and no act is lost or merged incorrectly

---

## Slice 6 — Capability: relationship-dates-lifecycle

### Requirement: Year-optional birth date

The system MUST accept a birth date with day and month only, omitting the
year, and MUST NOT compute or display an age for a year-less birth date.

#### Scenario: Year-less birthday fires with no age
- GIVEN a person has a day/month-only birth date
- WHEN their birthday nears the reminder window
- THEN the reminder shows the date but shows no age and no guessed year

#### Scenario: Full date still supports age
- GIVEN a person has a full year/month/day birth date
- WHEN their birthday nears the reminder window
- THEN the reminder shows the turning age, computed deterministically (per ADR-4)

### Requirement: Deceased/inactive flag suppresses all reminders for that person

The system MUST support a single boolean deceased/inactive marker per person.
When set, the system MUST NOT fire any birthday, contact-cadence, or context
reminder for that person.

#### Scenario: Deceased person fires nothing
- GIVEN a person is marked deceased
- WHEN the reminder pipeline runs on a date that would otherwise trigger their birthday
- THEN no reminder is produced for that person, on any surface

---

## Slice 7 — Capability: contact-clock-kind-parity (reverses proposal decision f)

The proposal deferred interaction `kind` because the drift gap (`MAX(ts)`
resetting the reach-out clock regardless of kind) is shared by
`lifeos/src/lifeos/relationships/people.py` (`last_contact`, `due_for_contact`)
and `mobile/lib/features/memory/domain/contact_nudge.dart` /
`relationship_reminders.dart` (`contactsDue`, `lastContact`). The user's
binding answer reverses this: he wants to log arguments/bad moments AND wants
them excluded from resetting the clock. This MUST ship as one coordinated
cross-platform change, never phone-only.

### Requirement: Interaction records carry a `kind`, and logging is never blocked

Both platforms MUST accept an interaction `kind` (at minimum: neutral/warm vs.
conflict) at the point an interaction is recorded. Recording a conflict
interaction MUST always be possible — the system MUST NOT refuse or hide the
ability to log an argument.

#### Scenario: Logging a conflict is always allowed
- GIVEN the user wants to record an argument with a person
- WHEN they log the interaction with kind "conflict"
- THEN it is saved exactly like any other interaction, with the kind recorded

### Requirement: Conflict-kind interactions do not reset the reach-out clock, on either platform

`people.py`'s `last_contact`/`due_for_contact` and the phone's
`contactsDue`/`lastContact` computation MUST both exclude conflict-kind
interactions from the "last real conversation" value used to decide whether
someone is due for contact.

#### Scenario: A recent conflict does not mask overdue contact
- GIVEN a person's last warm interaction was 40 days ago, cadence is 30 days, and a conflict interaction happened 2 days ago
- WHEN due-for-contact is computed on either platform
- THEN the person is surfaced as due; the conflict interaction is not treated as the last contact

#### Scenario: Only conflict interactions exist
- GIVEN a person has only conflict-kind interactions recorded, never a warm one
- WHEN due-for-contact is computed
- THEN the system falls back to the person's added/`created_at` date (the existing "never contacted" rule), and does not silently treat the conflict as contact

#### Scenario: Untyped legacy interactions keep today's behavior
- GIVEN an interaction was recorded before `kind` existed (or with no kind specified)
- WHEN due-for-contact is computed
- THEN it defaults to counting toward `last_contact`, exactly as today — no silent behavior change for existing data

### Requirement: Phone and laptop MUST NOT drift — shared parity tests are mandatory

The system MUST ship a shared fixture (person, interaction list including at
least one conflict-kind case, cadence, `now`) consumed by BOTH
`lifeos/tests/test_relationships_people_graph.py`-style Python tests and the
Dart test suite covering `contact_nudge.dart`/`relationship_reminders.dart`.

#### Scenario: Parity fixture produces identical results
- GIVEN the shared fixture is fed to both platforms' due-for-contact computation
- WHEN each platform computes days-since and the due/not-due decision
- THEN both produce byte-identical results (same due-list membership, same day counts) for every fixture case, including the conflict-kind case

#### Scenario: A future one-sided change is caught
- GIVEN a future PR changes only one platform's kind-handling logic
- WHEN the shared parity test suite runs
- THEN the mismatch fails the test, surfacing the drift instead of shipping it silently
