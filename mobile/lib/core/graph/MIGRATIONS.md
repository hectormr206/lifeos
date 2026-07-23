# Local Graph DB — Migration Protocol

The on-device graph is the user's memory/RAG/config store, encrypted at rest
(SQLCipher). The app auto-updates via OTA, so **no update may ever corrupt or
lose this data.** This document is the mandatory protocol for every schema
change. It is enforced by code (`local_graph_migrations.dart`) and by tests.

## The one rule

> **Every schema change = append ONE additive migration step + a vN→vN+1
> data-survival test. Additive-only. Never destructive.**

## Additive-only (enforced)

Migrations may only:

- `ALTER TABLE … ADD COLUMN` (nullable, or with a sensible default)
- `CREATE TABLE …`
- `CREATE INDEX …`
- backfill data (`INSERT`, `UPDATE`)

Migrations must **never**, on a user table:

- `DROP TABLE` / `DROP COLUMN`
- `DELETE` / `TRUNCATE`
- rename a table/column, or recreate-and-copy a table

`assertAdditiveMigrationStatement` rejects `DROP`/`DELETE`/`TRUNCATE`/`RENAME`/
`REPLACE INTO` at run time, so a destructive step fails loudly instead of
shipping.

## How the framework works

- `applyLocalGraphSchema()` (`local_graph_schema.dart`) is the **frozen v1
  base** — the starting point every installed device began from. Never edit it
  to add new columns/tables.
- `kGraphMigrations` is the **append-only, ordered** list of steps for v2, v3, …
- `onCreate` → `createLatestGraphSchema` = base + **all** migrations.
- `onUpgrade` → `runGraphMigrations(old, new)` = only the **missing** steps.

Because `onCreate` and a full `onUpgrade` chain replay the *same* migrations, a
fresh install and an upgraded install reach an **identical** final schema by
construction. `local_graph_migration_test.dart` asserts this.

## Non-destructive open guarantees

`openGuardedGraphDatabase` wraps every open:

- **Version mismatch / downgrade** (DB newer than the app) → refuse and throw;
  the file is left intact. Never wipe, never recreate.
- **Backup-before-migrate** → the file is copied to `<db>.bak` before any
  upgrade runs; a failed migration restores it.
- **Decrypt/open/migration failure** → the error is surfaced (backup restored);
  an empty DB is never silently created in place of the user's data.
- `onDowngrade` throws (never `onDatabaseDowngradeDelete`, which deletes).

## Adding a migration (checklist)

1. Append a `GraphMigration(version: N, …)` to `kGraphMigrations` with only
   additive `statements` (+ optional `backfill`).
2. Bump `kLocalGraphSchemaVersion` to `N`.
3. Add a `v(N-1) → vN` data-survival test to
   `local_graph_migration_test.dart`: seed real rows at `N-1`, open through the
   real migration path to `N`, assert **every row + relationship survives** with
   correct values and new columns get sensible defaults.
4. Never edit or reorder an already-shipped migration.

## Worked example — v2

`nodes.salience REAL` (nullable; default `NULL` = "unranked" for pre-existing
rows) + `updated_at` indexes on `nodes` and `edges`. Purely additive; the
v1→v2 test proves all v1 nodes, edges, and relationships survive untouched.
