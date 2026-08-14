# Graph Sync Specification

## Purpose

A push/pull/merge engine for `nodes` and `edges` only — the sole tables
carrying `uuid`/`origin_node`/`lamport`/`deleted_at`
(`axi/src/axi/store.py:219-274`). Last-writer-wins by `lamport`, with the
losing revision preserved, never silently destroyed. Automatic transfers run
only on WiFi. No other table is in scope.

## Requirements

### Requirement: Only `nodes` and `edges` participate in sync

The system MUST sync exclusively the `nodes` and `edges` tables. The system
MUST NOT sync `conversations`, `meetings`, `meeting_segments`,
`meeting_screenshots`, `chat_attachments`, `speakers`, `meeting_speakers`,
`reminders`, `events`, `brain_metrics`, `meta`, or `domain_node_map` — none
of these carry sync columns.

#### Scenario: A push/pull cycle touches only nodes and edges
- GIVEN a device with local changes across multiple tables including
  `reminders` and `nodes`
- WHEN a sync cycle runs
- THEN only `nodes` and `edges` rows MUST be transmitted or applied

### Requirement: `origin_node` is populated on every insert

Every `INSERT INTO nodes` and `INSERT INTO edges` MUST populate `origin_node`
with the authoring device's UUID.

#### Scenario: A newly inserted node records its origin
- GIVEN a device with an established device UUID
- WHEN it inserts a new node
- THEN the row's `origin_node` MUST equal that device's UUID, not NULL

### Requirement: Conflicts resolve by last-writer-wins on `lamport`, with the loser preserved

When two revisions of the same `uuid` conflict, the system MUST keep the
revision with the higher `lamport` value as the live row, and MUST write the
losing revision (uuid, losing lamport, losing origin, losing payload) to a
local `sync_conflicts` table on the applying device, visible via a
conflict-history view. Neither revision may be silently discarded.

#### Scenario: Two devices edit the same node offline, then sync
- GIVEN device A edits node X to lamport=5 and device B edits the same node
  X to lamport=7, both offline from each other
- WHEN they sync
- THEN node X MUST end up at the lamport=7 revision on both devices, and
  the lamport=5 revision MUST be recorded in `sync_conflicts` with its
  original payload and origin, retrievable from the conflict-history view

#### Scenario: Equal lamport values resolve deterministically
- GIVEN two revisions of the same node with identical `lamport` values but
  different `origin_node`
- WHEN they are compared during merge
- THEN the system MUST apply a fixed, deterministic tiebreak (lexicographically
  higher `origin_node` UUID wins) and MUST preserve the other revision in
  `sync_conflicts`, exactly as a non-tied conflict

### Requirement: Tombstones propagate and are never resurrected

A delete (`deleted_at` set) on one device MUST propagate to every other
device on next sync, and a device that has already applied a tombstone MUST
NOT resurrect the row from a stale, non-deleted revision.

#### Scenario: A delete on one device removes the row everywhere
- GIVEN device A deletes node X (`deleted_at` set)
- WHEN device B syncs
- THEN node X MUST be marked deleted on device B as well

#### Scenario: A stale un-deleted revision does not resurrect a tombstoned row
- GIVEN device A has tombstoned node X and device B still holds an older,
  non-deleted revision of X from before the delete
- WHEN device B syncs after A's delete has propagated
- THEN node X MUST remain deleted; the older revision MUST NOT resurrect it

#### Scenario: Delete dominates a concurrent edit with a HIGHER lamport
- GIVEN device A tombstones node X at lamport 5
- AND device B, offline and unaware of the delete, edits X at lamport 7
- WHEN the two devices sync
- THEN node X MUST remain deleted on both devices even though the edit has
  the higher lamport, and B's losing revision MUST be preserved in
  `sync_conflicts`

This is a deliberate deviation from pure last-writer-wins, and it is the ONLY
one. Rationale: in an app holding a person's whole life, a deletion is a
deliberate act, and silently resurrecting data the user believed erased is a
privacy failure, not a merge outcome. Nothing is lost — the losing edit is
preserved in `sync_conflicts` and visible in conflict history, so the user can
restore it deliberately if the delete was the mistake.

### Requirement: An edge may legally arrive before its node

The system MUST accept an edge whose `src_uuid` or `dst_uuid` does not yet
match any local node, and MUST resolve the reference once the matching node
arrives, without rejecting or dropping the edge.

#### Scenario: Edge syncs before its source node
- GIVEN an edge referencing a `src_uuid` not yet present locally
- WHEN the edge is applied during sync
- THEN it MUST be stored with the dangling `src_uuid` and MUST become fully
  resolved once a node with that `uuid` is later synced, with no data loss

### Requirement: Automatic sync transfers occur only on WiFi

The system MUST NOT initiate automatic push/pull transfers over a cellular
or metered connection; manual, user-initiated sync MAY be permitted
regardless of connection type.

#### Scenario: Automatic sync waits for WiFi
- GIVEN pending local changes and an active cellular connection with no WiFi
- WHEN the automatic sync interval elapses
- THEN no automatic transfer MUST occur until WiFi becomes available
