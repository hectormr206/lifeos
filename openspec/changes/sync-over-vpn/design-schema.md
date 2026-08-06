# Design: sync-over-vpn — SCHEMA convergence (supersedes design.md "Slice 3" only)

Slices 1–2 of `design.md` shipped correctly (PR1–PR3) and stand. PR4 shipped
`migrate_nodes_edges_sync_columns` (`axi/src/axi/store.py:2666`). This document
replaces only the slice-3 section, correcting its framing error: the target
schema is NOT invented here. It ships in production as
`mobile/lib/core/graph/local_graph_schema.dart` (frozen v1 base, additive-only
migration discipline, holding the owner's real data). **Axi converges toward
mobile's shape**; mobile does not move.

## Verified divergences (axi `store.py:199-241` vs mobile v1 base)

| Concern | mobile (target) | axi (current, post-PR4) | Verified |
|---|---|---|---|
| edge endpoints | `src_uuid`/`dst_uuid` TEXT NOT NULL | `from_id`/`to_id` INTEGER FK `ON DELETE CASCADE` (store.py:227-228) | yes |
| edge relation column | `relation` | `kind` (store.py:229) | yes |
| edge `updated_at` | present NOT NULL | absent | yes |
| node `occurred_at` | present (nullable) | absent | yes |
| `uuid` | `NOT NULL UNIQUE` column constraint | nullable column + UNIQUE index (store.py:211,223,233,241) | yes |
| `lamport` | `NOT NULL DEFAULT 0` | nullable (store.py:212,234) | yes |
| `deleted_at` indexes | `idx_nodes_deleted`, `idx_edges_deleted` | absent | yes (extends the given list) |
| `origin_node`, `deleted_at` columns | present | present (PR4) | yes |

Node `kind`, `label`, `data`, `domain`, `created_at`, `updated_at`,
`created_tz` already agree.

## Decision 1: Axi converges to mobile's exact column names and constraints

**Choice**: axi's `nodes`/`edges` end at mobile's exact v1-base shape
(plus axi-only sidecars `nodes_fts`/`vec_nodes`, which are local derived
state, never synced). No third shape. No permanent mapping layer.

**Rejected**:
- *Mobile converges to axi* — axi's shape is the legacy one (rowid
  endpoints cannot sync at all: rowid 42 on the laptop is not rowid 42 on
  the Pixel, stated verbatim in the mobile DDL doc comment). Mobile's
  migration discipline forbids renames/drops, so it structurally cannot
  adopt `from_id`/`kind` even if we wanted it to.
- *Both meet at a third shape* — forces a migration on BOTH production
  datasets for zero benefit; doubles blast radius.
- *Permanent sync-boundary mapper (schemas stay divergent)* — keeps two
  dialects alive forever; the `kind`/`relation` silent-mis-map failure
  becomes a permanent standing risk instead of a one-time cost.

**Blast radius stated**: renaming in axi touches every reader of
`from_id`/`to_id`/edge-`kind`: `store.py` (~10 SQL sites incl. 1281, 1321,
1382-1416, 2973-2978), `forget.py:211-212`, `recall.py:271-273`,
`linkers.py:44-64`, `identity.py:354-355, 392, 453, 501, 555-557, 596,
628, 690`, `dashboard.py:2252-2263, 2526-2538, 2719-2733, 2951-2980`,
`meeting.py` (via store helpers only). Roughly 40 SQL sites, all
mechanical join/name rewrites. Mobile changes: zero.

## Decision 2: Expand → migrate readers → contract (endpoints and rename)

Straight rename-in-place is impossible in SQLite without a table rebuild,
and a big-bang rebuild+rewrite blows the 400-line budget and mixes the
irreversible step with reviewable code churn. Sequence instead:

1. **Expand (reversible)**: `ALTER TABLE edges ADD COLUMN src_uuid TEXT` /
   `dst_uuid TEXT`, backfilled from `nodes.uuid` via `from_id`/`to_id`;
   `updated_at REAL` backfilled `= created_at`; `relation` as
   `GENERATED ALWAYS AS (kind) VIRTUAL` (single storage — cannot drift);
   `nodes.occurred_at REAL`. Writers dual-write endpoints:
   `add_edge` (store.py:1281), similar-to insert (store.py:2978),
   `linkers._safe_insert_edge` (linkers.py:63), and the identity merge
   (`identity.py:354-355` must update `src_uuid`/`dst_uuid` in the same
   transaction). A drift check (`verify_edge_endpoint_convergence()`)
   asserts `src_uuid = (SELECT uuid FROM nodes WHERE id = from_id)` for
   every live edge; any mismatch RAISES — per the LifeOS silent-failure
   rule, a check that cannot run also raises.
2. **Migrate readers (reversible)**: rewrite all read sites to
   `src_uuid`/`dst_uuid` joins and `e.relation`. Old columns still exist
   and are maintained, so this PR reverts cleanly.
3. **Contract (THE POINT OF NO RETURN)**: single table rebuild to
   mobile's exact DDL — drops `from_id`/`to_id`, renames `kind`→`relation`
   as real storage, tightens `uuid NOT NULL UNIQUE` and
   `lamport NOT NULL DEFAULT 0`, and the `ON DELETE CASCADE` FK ceases to
   exist because the columns carrying it do.

**CASCADE re-examined**: the prior design's "leave it inert" answer relied
on never issuing `DELETE FROM nodes`. That holds only AFTER the tombstone
PR lands; until then any hard node delete silently cascades edges away.
Therefore the tombstone PR MUST precede the rebuild PR (ordering below).
After the rebuild there is no FK at all: referential integrity moves to
the application, matching mobile, where a dangling `src_uuid` is legal by
design (an edge may sync before its node). A loud (report-only) dangling-
edge check joins the post-migration verification.

**Rejected**: generated-column alias forever (dual naming, drift on the
write side); mapper-only rename (silent); rebuild-first (irreversible step
would carry 40 sites of code churn through review).

**Loudness of the rename**: after the contract PR, any missed `e.kind` or
`from_id` SQL fails with `no such column` at the first execution — the
silent-mis-assignment failure mode is converted into a hard error by
construction, plus the full suite runs between every PR.

## Decision 3: Delete paths become tombstones; FTS/vec rows still hard-delete

Enumerated (verified by grep; extends the given list):

| Site | What | Treatment |
|---|---|---|
| `store.py:1321` delete edges of node | tombstone: `UPDATE edges SET deleted_at=?, updated_at=? WHERE (src_uuid=? OR dst_uuid=?) AND deleted_at IS NULL` | same tx as node |
| `store.py:1322` `nodes_fts` row | keep HARD delete — FTS is local derived state, never synced | same tx |
| `store.py:1325` `vec_nodes` row (missed by the given list) | keep hard delete, best-effort as today | same tx |
| `store.py:1328` node | tombstone | |
| `store.py:1350` `delete_edge` | tombstone | |
| `meeting.py:881-882` race-loser orphan | tombstone node + hard-delete FTS row | orphan tombstones are accepted noise |
| `identity.py:356-357,359` alias-merge loser (+`vec_nodes` at 359, missed by the given list) | tombstone node + hard-delete FTS/vec rows; endpoint rewrite at 354-355 dual-updates uuids until contract PR | |
| `lifeos/src/lifeos/edges.py:149` | **OUT OF SCOPE — verified**: deletes from the `lifeos` package's OWN `edges` table (`lifeos/src/lifeos/store.py:187` — TEXT ulid `id`, `src_domain`/`dst_domain`/`rel`), a different database, not axi's `memory.db` graph and not what mobile mirrors. Named follow-up: decide whether that store ever syncs. | none here |

Reads filter `deleted_at IS NULL`; add `idx_nodes_deleted`/
`idx_edges_deleted` (mobile parity). **FTS invariant, made loud**: a
post-migration and test-suite check asserts no `nodes_fts.rowid` joins a
node with `deleted_at NOT NULL` — search returning deleted memories is
the named worst-case. Future remote-tombstone application (sync follow-up)
must also delete the FTS row; recorded as a hard precondition there.
`write_router.maybe_forward` needs no change: routed deletes execute the
same store functions in the daemon process — one implementation.

## Decision 4: PR boundaries (feature-branch-chain, ≤400 production lines each)

| PR | Content | Reversible? | Budget risk |
|---|---|---|---|
| **PR5** | Expand: columns + backfill + dual-write + drift check + tests | Yes (revert PR; extra columns lie fallow) | Low |
| **PR6** | Reader rewrite to `src_uuid`/`dst_uuid`/`relation` (~40 sites). If diff exceeds 400, split `dashboard.py` into PR6b | Yes | **High — pre-split into 6a/6b recommended** |
| **PR7** | Tombstone all delete paths, `deleted_at IS NULL` filters, deleted indexes, FTS invariant check | Code-revert possible, but reverting RESURRECTS soft-deleted rows — semantically one-way once a delete happens | Medium |
| **PR8** | **THE POINT OF NO RETURN**: verified backup gate + single-transaction table rebuild to mobile DDL + in-transaction verification | No — old columns/constraints gone; recovery = restore backup | Low (small, isolated by design) |

PR8 is deliberately the smallest: the irreversible step ships with nothing
else in the diff.

## Decision 5: Backup gate for PR8 — verified, not assumed

Before the rebuild transaction begins, in order, each step aborting loudly
on failure OR on inability to run:

1. `VACUUM INTO '<db-dir>/memory.pre-rebuild-<ts>.db'` — transactional
   snapshot; safe against concurrent writers, unlike a file copy. No new
   dependency (SQLite ≥3.27; SQLCipher carries the key into the output).
2. Re-open the snapshot with the same key; `PRAGMA integrity_check` must
   return `ok` — proves *restorable*, not just *written*.
3. Row-count parity: `nodes`, `edges`, `nodes_fts` counts in snapshot ==
   live DB; spot-check a sample of `(id, uuid)` pairs.
4. Only then `BEGIN IMMEDIATE` the rebuild.

The backup step is an injected callable on the migration entry point so
tests fake success, failure, and a snapshot that fails `integrity_check`
(Strict TDD: no real device, no real key ceremony needed).

**Rejected**: trusting the existing manual backup-host backup (age
unknown at migration time); file-level copy (torn copy under WAL/journal
activity is exactly the un-restorable backup this gate exists to catch).

## Decision 6: Interrupted-migration safety

- Each PR's migration stage is gated by `PRAGMA user_version` (PR5=1,
  PR7=2, PR8=3 for this table pair), checked before acting — re-runs are
  idempotent no-ops, matching the PR4 pattern.
- PR5 backfill reuses PR4's convergent per-row pattern (only touches
  rows where the target column IS NULL) — kill-safe at any point.
- PR8's rebuild runs as: `PRAGMA foreign_keys=OFF` → `BEGIN IMMEDIATE` →
  `CREATE TABLE nodes_new/edges_new` (mobile DDL) → `INSERT INTO ... SELECT`
  (explicit `id` copy — never AUTOINCREMENT reassignment, so
  `conversations.node_id`/`meetings.node_id` FKs stay valid) →
  **verification INSIDE the transaction while old and new tables coexist**
  (row counts equal; `SUM`-based checksums over `uuid`, endpoints,
  `relation`; zero NULL uuids; id→uuid mapping intact per spec) →
  `DROP`/`RENAME` → set `user_version` → `COMMIT` → `PRAGMA
  foreign_key_check` → `PRAGMA foreign_keys=ON`. A kill at ANY point
  before COMMIT rolls back to the intact old schema; the connection used
  is autocommit (`isolation_level=None`, per store.py convention), so the
  explicit `BEGIN IMMEDIATE` is mandatory, not optional.
- Verification failure inside the transaction raises → rollback → old
  schema untouched → loud error. Verification is never post-commit.

## Testing Strategy

| Layer | What | Approach |
|---|---|---|
| Unit | drift check raises on divergence AND on being unable to run; backup gate aborts on fake failure/corrupt snapshot; FTS invariant | tmp SQLCipher DB, injected backup callable |
| Migration | old-shape seeded DB → PR5/PR7/PR8 stages; kill-simulation (raise mid-stage) → re-run converges; `user_version` idempotence | pytest tmp DB, per PR4's test pattern |
| Verification | rebuild with a deliberately dropped row → in-transaction verification fails → rollback proven | seeded tmp DB |
| Regression | full axi suite green after every PR (zero-behavior-change claim per PR5/PR6/PR8) | CI |

## Threat Matrix

N/A — no routing, shell, subprocess, VCS/PR automation, executable-file
classification, or process-integration boundary. (`write_router` is
pre-existing and unchanged.)

## Migration / Rollout

PR5→PR6(a/b)→PR7→PR8 chained on the feature branch. Rollback: PR5/PR6
revert cleanly; PR7 revert resurrects soft-deleted rows (documented,
accepted only pre-release of PR8); PR8 recovery is restore-from-verified-
backup only.

## Open Questions

- [ ] Does the `lifeos` package's cross-domain edge store ever enter sync
  scope? (Out of this change; blocks nothing here.)
- [ ] Purge/GC of old tombstones remains a named follow-up (unchanged from
  design.md 3b).

## VERIFIED: `VACUUM INTO` on SQLCipher (was an open risk)

The design listed this as unverified — "stated from SQLite/SQLCipher
documentation knowledge, not proven here" — and it gates the backup that gates
the irreversible rebuild. Measured directly against `sqlcipher3` rather than
left for PR8's first test:

```
source keyed with K, VACUUM INTO snapshot
  snapshot opened WITH K     -> opens, all rows present
  snapshot opened WITHOUT K  -> DatabaseError
```

Both halves matter. The first is what the design assumed: the snapshot carries
the key and is restorable. The SECOND was not asked about and is the one that
would have hurt — had `VACUUM INTO` emitted plaintext, the safety backup taken
before the irreversible step would itself have been an unencrypted dump of the
entire graph sitting on disk. A privacy failure hiding inside a safety
mechanism.

PR8's first test should still assert this in CI, so a future SQLCipher upgrade
that changes the behaviour fails loudly rather than silently producing plaintext
backups.
