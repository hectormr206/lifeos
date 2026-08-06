# Local Graph DB — Migration Protocol

The on-device graph is the user's memory/RAG/config store, encrypted at rest
(SQLCipher). The app auto-updates via OTA, so **no update may ever corrupt or
lose this data.** This document is the mandatory protocol for every schema
change. It is enforced by code (`local_graph_migrations.dart`) and by tests.

## One framework, two backends

The migration framework in this folder is **platform-neutral and
single-sourced**. Only the keyed open differs, behind `GraphDatabaseBackend`
(`graph_database_backend.dart`):

| Platform | Backend | SQLCipher |
|---|---|---|
| Android / iOS / macOS | `sqflite_sqlcipher` native plugin | 4.10.0 |
| Linux / Windows | `sqflite_common_ffi` over `package:sqlite3` | 4.17.0 community |

Desktop gets its cipher from the `hooks: user_defines: sqlite3: source:
sqlcipher` block in `pubspec.yaml`. **Without it, `PRAGMA key` is a silent
no-op and the graph would be plaintext** — so `SqlCipherFfiGraphBackend` proves
`PRAGMA cipher_version` on every open and refuses to return a handle otherwise.
There is no plaintext fallback anywhere on either backend.

Both write the same file: the 64-hex keystore key is a SQLCipher *passphrase*
(PBKDF2-HMAC-SHA512, 256 000 iterations, HMAC-SHA512, 4096-byte pages —
asserted in `sqlcipher_ffi_backend_test.dart`). A **major** SQLCipher bump on
one side only would break that interchange, which matters for device sync.

Adding a migration therefore needs no per-platform work. Adding a *platform*
means implementing the two methods of `GraphDatabaseBackend` and nothing else.

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
